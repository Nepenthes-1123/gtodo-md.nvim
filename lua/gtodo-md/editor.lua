local M = {}
local task_mod = require("gtodo-md.task")
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")
local logic_mod = require("gtodo-md.logic")

-- カーソル行がタスクか判定
function M.get_current_task()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
	if not line then
		return nil
	end
	local task = task_mod.parse(line)
	return task, row, line
end

-- カーソル位置のセクションを特定する
function M.get_current_section()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
	for i = #lines, 1, -1 do
		local sec_name = lines[i]:match("^##%s+(.*)$")
		if sec_name then
			return vim.trim(sec_name)
		end
	end
	return "default"
end

-- BUG-5/BUG-15対応: todo.md内のタスク検索・更新の共通ヘルパー
-- action_fn(todo_data, section, idx) を受け取って変更を加える
-- タスクが見つかれば true、見つからなければ false を返す

-- P1-4/#82: タスク同定ヘルパー（テスト可能なパブリック関数）
-- Primary   : task.id と item.task.id の完全一致（一意なIDによる最も信頼できる同定）
-- Secondary : task.original_line と item.task.original_line の完全一致（BUG-19 互換性維持）
-- Fallback  : content + created の一致（IDがまだ発行されていない旧形式のタスク向け）
--
-- #82の経緯: content+createdが同一の重複タスクが複数存在する場合、Fallbackだけでは
-- どちらか一方を区別できず誤操作の原因になっていた。write_todo_file 等でファイルに
-- 書き戻されたタスクは一意なIDを持つため、Primaryで確実に区別できるようになる。
-- ただし手入力直後などIDがまだ無いタスクも存在しうるため、Secondary/Fallbackは
-- 後方互換のため残す。
--
-- BUG-19 の経緯:「split後に original_line が古くなる」問題があった。
-- ここで参照する original_line は task.parse() が生成した「その時点でのバッファ行」
-- であり、io_mod.read_todo_file() が生成したアイテムの original_line と
-- バッファ・ファイルが同期している限り一致する。保存した古い値を使う訳ではないので
-- BUG-19 の問題は生じない。
function M._find_task_idx(sec_items, task)
	-- Primary: id で完全一致
	if task.id and task.id ~= "" then
		for i, item in ipairs(sec_items) do
			if item.type == "task" and item.task.id == task.id then
				return i
			end
		end
	end

	local orig = task.original_line

	-- Secondary: original_line で完全一致（重複タスクを行テキストで区別）
	if orig and orig ~= "" then
		for i, item in ipairs(sec_items) do
			if item.type == "task" and item.task.original_line == orig then
				return i
			end
		end
	end

	-- Fallback: content + created（original_line が nil や空の場合、
	-- または serialize ラウンドトリップで original_line が欠落した場合）
	for i, item in ipairs(sec_items) do
		if item.type == "task" and item.task.content == task.content and item.task.created == task.created then
			return i
		end
	end

	return nil
end

-- io.write_lines は書き込み失敗時に error を投げる。キーマップ経由の操作は
-- lock.with_automation_lock の外側で走るため誰も pcall しておらず、そのままでは
-- 生の例外がユーザーへ表面化してしまう。ここで捕まえて通知に変える。
local function protected_write(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
	end
	return ok
end

-- カレントバッファの1行を差し替える(replacement を渡す)か取り除いた(nil を渡す)結果を
-- ファイルへ確定させる。書き込みに失敗した場合は error を投げる。
--
-- 生の `:write` を使ってはならない。io.lua を経由しないためアトミック置換も
-- 並行更新検出も掛からず、さらに `pcall(vim.cmd, "write")` の戻り値を見ない実装が
-- 失敗を握り潰していた(inbox 側の削除が失敗しても todo.md への追記が続行され、
-- タスクが重複または消失していた)。
--
-- 行が既に存在しない場合は false を返す(呼び出し元が「追記済みだが削除できなかった」
-- ことをユーザーへ伝えられるようにするため。ここで error にすると区別できない)。
-- `expected_line` を渡すと、その行テキストで対象行を確認し直す。
-- Waiting への移動は `vim.ui.input` で待ち先を尋ねる間 row をクロージャに抱えたまま
-- 待機するが、その間にも自動処理や外部変更リロードは走るため行がずれうる。
-- 確認しないと無関係な行を書き換える/削除することになる。
local function locate_row(lines, row, expected_line)
	if not expected_line or lines[row] == expected_line then
		return row
	end
	for i, line in ipairs(lines) do
		if line == expected_line then
			return i
		end
	end
	return nil
end

local function commit_current_buffer_line(path, row, replacement, expected_line)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local target = locate_row(lines, row, expected_line)
	if not target or target < 1 or target > #lines then
		return false
	end
	if replacement then
		lines[target] = replacement
	else
		table.remove(lines, target)
	end
	io_mod.write_lines(path, lines)
	return true
end

-- 戻り値: 成功なら true、失敗なら false と理由("notfound" / "write")。
-- "write" の場合はこの関数が既に通知済みなので、呼び出し元は追加の通知をしない。
local function update_task_in_todo(task, section, action_fn)
	local todo_path = config.get("data_dir") .. "/todo.md"
	local todo_data = io_mod.read_todo_file(todo_path)

	if not todo_data.sections[section] then
		return false, "notfound"
	end

	local sec_items = todo_data.sections[section]
	local found_idx = M._find_task_idx(sec_items, task)

	if not found_idx then
		return false, "notfound"
	end

	action_fn(todo_data, section, found_idx, sec_items)
	if not protected_write(io_mod.write_todo_file, todo_path, todo_data) then
		return false, "write"
	end
	return true
end

-- todo.md内のタスクの完了トグルを実行する。カーソル位置に依存しないコア処理で、
-- カーソル版(M.toggle_complete)とカンバンビュー(ui/kanban.lua)の両方から呼ばれる。
function M.toggle_task_complete(task, section)
	local is_completed = (task.status == "x")
	local today = os.date("%Y-%m-%d")
	local ok, reason = update_task_in_todo(task, section, function(todo_data, sec, idx, sec_items)
		local t = sec_items[idx].task
		if is_completed then
			t.status = " "
			t.completed_at = nil
		else
			t.status = "x"
			t.completed_at = today
		end
		todo_data.sections[sec] = logic_mod.sort_section_tasks(todo_data.sections[sec])
	end)
	if not ok and reason == "notfound" then
		vim.notify("Task not found in todo.md.", vim.log.levels.WARN)
	end
	return ok
end

-- 完了トグル
function M.toggle_complete()
	local task, row = M.get_current_task()
	if not task then
		vim.notify("Not on a task line.", vim.log.levels.WARN)
		return
	end

	local bufname = vim.api.nvim_buf_get_name(0)
	local filename = vim.fn.fnamemodify(bufname, ":t")

	if filename == "todo.md" then
		M.toggle_task_complete(task, M.get_current_section())
	else
		local today = os.date("%Y-%m-%d")
		local is_completed = (task.status == "x")
		if is_completed then
			task.status = " "
			task.completed_at = nil
		else
			task.status = "x"
			task.completed_at = today
		end
		local newline = task_mod.serialize(task)
		local found
		local ok = protected_write(function()
			found = commit_current_buffer_line(bufname, row, newline, task.original_line)
		end)
		if ok and not found then
			vim.notify("Task line not found.", vim.log.levels.WARN)
		end
	end
end

-- タスクのセクション移動の実装部分
function M._execute_move(task, row, target_section)
	local bufname = vim.api.nvim_buf_get_name(0)
	local filename = vim.fn.fnamemodify(bufname, ":t")

	local data_dir = config.get("data_dir")
	local todo_path = data_dir .. "/todo.md"

	if filename == "inbox.md" then
		local todo_data = io_mod.read_todo_file(todo_path)
		if #todo_data.section_order == 0 then
			todo_data.section_order = vim.tbl_map(function(key)
				return config.sections[key]
			end, config.section_order)
		end
		if not todo_data.sections[target_section] then
			todo_data.sections[target_section] = {}
		end
		table.insert(todo_data.sections[target_section], { type = "task", task = task })
		todo_data.sections[target_section] = logic_mod.sort_section_tasks(todo_data.sections[target_section])

		-- todo.md への追記が先、inbox.md からの削除が後(logic/write_pair 参照)。
		-- 逆順だと、追記が失敗したときタスクがどちらのファイルにも残らず消える。
		local removed
		local ok = protected_write(logic_mod.append_then_remove, function()
			io_mod.write_todo_file(todo_path, todo_data)
		end, function()
			removed = commit_current_buffer_line(bufname, row, nil, task.original_line)
		end, data_dir)

		if not ok then
			return
		end
		if not removed then
			-- 追記は済んでいるので消失はしていないが、元の行が残る(＝重複)。
			vim.notify(
				"Task was added to todo.md but the original line in inbox.md could not be found. "
					.. "Please delete the remaining line manually.",
				vim.log.levels.WARN
			)
			return
		end
		vim.notify(string.format("Moved task to todo.md [%s]", target_section), vim.log.levels.INFO)
	elseif filename == "todo.md" then
		local current_sec = M.get_current_section()
		M.move_task_between_sections(task, current_sec, target_section)
	end
end

-- todo.md内でのセクション間移動を実行する。カーソル位置に依存しないコア処理で、
-- カーソル版(M._execute_move)とカンバンビュー(ui/kanban.lua)の両方から呼ばれる。
-- 戻り値: 実際に移動(またはwait:の更新)が行われたかどうか
function M.move_task_between_sections(task, current_section, target_section)
	if current_section == target_section then
		-- Waiting 内での操作だけは no-op にしない。セクション移動は起きないが、
		-- 待ち先(wait:)を変更する手段がこの経路以外に存在しないため、
		-- 同一セクションであっても wait: の更新だけは受け付ける。
		if target_section == config.sections.WAITING then
			local updated, reason = update_task_in_todo(task, current_section, function(_, _, idx, sec_items)
				sec_items[idx].task.wait = task.wait
			end)
			if updated then
				vim.notify(string.format("Updated wait: in [%s]", target_section), vim.log.levels.INFO)
			elseif reason == "notfound" then
				vim.notify("Task not found in current section.", vim.log.levels.WARN)
			end
			return updated
		end

		vim.notify("Already in " .. target_section, vim.log.levels.INFO)
		return false
	end

	-- BUG-15対応: update_task_in_todo の戻り値を確認してから notify
	local moved = false
	local ok, reason = update_task_in_todo(task, current_section, function(todo_data, section, idx, sec_items)
		table.remove(sec_items, idx)

		if not todo_data.sections[target_section] then
			todo_data.sections[target_section] = {}
			local has_sec = false
			for _, s in ipairs(todo_data.section_order) do
				if s == target_section then
					has_sec = true
					break
				end
			end
			if not has_sec then
				table.insert(todo_data.section_order, target_section)
			end
		end

		table.insert(todo_data.sections[target_section], { type = "task", task = task })
		todo_data.sections[section] = logic_mod.sort_section_tasks(todo_data.sections[section] or {})
		todo_data.sections[target_section] = logic_mod.sort_section_tasks(todo_data.sections[target_section])
		moved = true
	end)

	if ok and moved then
		vim.notify(string.format("Moved task to [%s]", target_section), vim.log.levels.INFO)
	elseif reason == "notfound" then
		vim.notify("Task not found in current section.", vim.log.levels.WARN)
	end
	return ok and moved
end

-- カーソルに依存せず、タスクと現在のセクションを引数にとる移動リクエスト。
-- カンバンビュー(ui/kanban.lua)専用。inbox.mdからの移動は扱わない
-- (カンバンはtodo.mdのセクションのみを表示するため、移動元は常にtodo.md内)。
-- 完了済みタスクの拒否・Waiting移動時のwait:入力プロンプトは
-- M.move_current_task_to と同じ挙動にする。
function M.request_move_task_to(task, current_section, target_section)
	if task.status == "x" then
		vim.notify("Cannot move a completed task.", vim.log.levels.WARN)
		return
	end

	if target_section == config.sections.WAITING then
		vim.ui.input({ prompt = "Waiting for (empty to skip/remove): ", default = task.wait or "" }, function(input)
			if input == nil then
				return
			end -- aborted
			local trimmed = vim.trim(input)
			task.wait = (trimmed ~= "") and trimmed or nil
			M.move_task_between_sections(task, current_section, target_section)
		end)
	else
		task.wait = nil
		M.move_task_between_sections(task, current_section, target_section)
	end
end

-- タスクのセクション移動 (エントリーポイント)
function M.move_current_task_to(target_section)
	local task, row = M.get_current_task()
	if not task then
		vim.notify("Not on a task line.", vim.log.levels.WARN)
		return
	end

	-- 完了済みタスクは done.md への繰り込み待ちであり、セクションの区別を持たない。
	-- 移動を許すと繰り込み前後で置き場所が変わるだけで意味が無いため受け付けない。
	-- wait: の付与も同じ理由でここで弾かれる。
	if task.status == "x" then
		vim.notify("Cannot move a completed task.", vim.log.levels.WARN)
		return
	end

	if target_section == config.sections.WAITING then
		vim.ui.input({ prompt = "Waiting for (empty to skip/remove): ", default = task.wait or "" }, function(input)
			if input == nil then
				return
			end -- aborted
			local trimmed = vim.trim(input)
			if trimmed ~= "" then
				task.wait = trimmed
			else
				task.wait = nil
			end
			M._execute_move(task, row, target_section)
		end)
	else
		task.wait = nil
		M._execute_move(task, row, target_section)
	end
end

-- タスクのキャンセル
function M.cancel_current_task()
	local task, row = M.get_current_task()
	if not task then
		vim.notify("Not on a task line.", vim.log.levels.WARN)
		return
	end

	local bufname = vim.api.nvim_buf_get_name(0)
	local filename = vim.fn.fnamemodify(bufname, ":t")
	local today = os.date("%Y-%m-%d")
	local current_month = today:sub(1, 7)
	local data_dir = config.get("data_dir")
	local cancelled_path = data_dir .. "/cancelled.md"

	-- キャンセル日を記録する。task.lua は `cancelled:` をパースもシリアライズもするが、
	-- この値を設定する経路がどこにも無く、完了時の completed_at と非対称に情報が
	-- 欠落したまま cancelled.md へ記録されていた。
	-- 同定に使うのは id / original_line / content+created なので、ここでの変更が
	-- 後段の _find_task_idx による削除対象の特定に影響することはない。
	task.cancelled = today

	-- cancelled.md への追記が先、元ファイルからの削除が後(logic/write_pair 参照)。
	-- 逆順だと、追記が失敗したときタスクがどちらのファイルにも残らず消える。
	local removed_reason
	local ok = protected_write(logic_mod.append_then_remove, function()
		logic_mod.append_to_history(cancelled_path, "Cancelled", current_month, { task })
	end, function()
		if filename == "todo.md" then
			local current_sec = M.get_current_section()
			local updated, reason = update_task_in_todo(task, current_sec, function(_, _, idx, sec_items)
				table.remove(sec_items, idx)
			end)
			if not updated then
				removed_reason = reason
			end
		else
			if not commit_current_buffer_line(bufname, row, nil, task.original_line) then
				removed_reason = "notfound"
			end
		end
	end, data_dir)

	if not ok then
		return
	end
	if removed_reason == "notfound" then
		-- 追記は済んでいるので消失はしていないが、元の行が残る(＝重複)。
		vim.notify(
			"Task was recorded in cancelled.md but could not be removed from the source file. "
				.. "Please delete the remaining line manually.",
			vim.log.levels.WARN
		)
		return
	end
	if removed_reason then
		-- 書き込み失敗は update_task_in_todo 側で通知済み
		return
	end
	vim.notify("Task cancelled and moved to cancelled.md", vim.log.levels.INFO)
end

function M.split_current_task()
	require("gtodo-md.ui.split").split_current_task()
end

return M
