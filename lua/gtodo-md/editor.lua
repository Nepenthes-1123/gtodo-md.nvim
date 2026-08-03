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

local function update_task_in_todo(task, section, action_fn)
	local todo_path = config.get("data_dir") .. "/todo.md"
	local todo_data = io_mod.read_todo_file(todo_path)

	if not todo_data.sections[section] then
		return false
	end

	local sec_items = todo_data.sections[section]
	local found_idx = M._find_task_idx(sec_items, task)

	if not found_idx then
		return false
	end

	action_fn(todo_data, section, found_idx, sec_items)
	io_mod.write_todo_file(todo_path, todo_data)
	return true
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
	local today = os.date("%Y-%m-%d")
	local is_completed = (task.status == "x")

	if filename == "todo.md" then
		local current_sec = M.get_current_section()
		local ok = update_task_in_todo(task, current_sec, function(todo_data, section, idx, sec_items)
			local t = sec_items[idx].task
			if is_completed then
				t.status = " "
				t.completed_at = nil
			else
				t.status = "x"
				t.completed_at = today
			end
			todo_data.sections[section] = logic_mod.sort_section_tasks(todo_data.sections[section])
		end)
		if not ok then
			vim.notify("Task not found in todo.md.", vim.log.levels.WARN)
		end
	else
		if is_completed then
			task.status = " "
			task.completed_at = nil
		else
			task.status = "x"
			task.completed_at = today
		end
		local newline = task_mod.serialize(task)
		local buf = vim.api.nvim_get_current_buf()
		local set_ok, err = pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, { newline })
		if not set_ok then
			vim.notify("Failed to update task line: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		pcall(vim.api.nvim_buf_call, buf, function()
			vim.cmd("write")
		end)
	end
end

-- タスクのセクション移動の実装部分
function M._execute_move(task, row, target_section)
	local bufname = vim.api.nvim_buf_get_name(0)
	local filename = vim.fn.fnamemodify(bufname, ":t")

	local data_dir = config.get("data_dir")
	local todo_path = data_dir .. "/todo.md"

	if filename == "inbox.md" then
		local buf = vim.api.nvim_get_current_buf()
		local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, {})
		if not ok then
			vim.notify("Failed to remove task from inbox: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		pcall(vim.api.nvim_buf_call, buf, function()
			vim.cmd("write")
		end)

		local todo_data = io_mod.read_todo_file(todo_path)
		if #todo_data.section_order == 0 then
			todo_data.section_order =
				{ config.sections.TODAY, config.sections.NEXT, config.sections.WAITING, config.sections.SOMEDAY }
		end
		if not todo_data.sections[target_section] then
			todo_data.sections[target_section] = {}
		end
		table.insert(todo_data.sections[target_section], { type = "task", task = task })
		todo_data.sections[target_section] = logic_mod.sort_section_tasks(todo_data.sections[target_section])
		io_mod.write_todo_file(todo_path, todo_data)
		vim.notify(string.format("Moved task to todo.md [%s]", target_section), vim.log.levels.INFO)
	elseif filename == "todo.md" then
		local current_sec = M.get_current_section()
		if current_sec == target_section then
			vim.notify("Already in " .. target_section, vim.log.levels.INFO)
			return
		end

		-- BUG-15対応: update_task_in_todo の戻り値を確認してから notify
		local moved = false
		local ok = update_task_in_todo(task, current_sec, function(todo_data, section, idx, sec_items)
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
		elseif not ok then
			vim.notify("Task not found in current section.", vim.log.levels.WARN)
		end
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
			if vim.trim(input) ~= "" then
				task.wait = vim.trim(input)
			elseif input == "" then
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

	if filename == "todo.md" then
		local current_sec = M.get_current_section()
		local ok = update_task_in_todo(task, current_sec, function(_, _, idx, sec_items)
			table.remove(sec_items, idx)
		end)
		if not ok then
			vim.notify("Task not found in todo.md.", vim.log.levels.WARN)
			return
		end
	else
		local buf = vim.api.nvim_get_current_buf()
		local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, {})
		if not ok then
			vim.notify("Failed to remove task line: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		pcall(vim.api.nvim_buf_call, buf, function()
			vim.cmd("write")
		end)
	end

	local current_month = os.date("%Y-%m")
	local data_dir = config.get("data_dir")
	local cancelled_path = data_dir .. "/cancelled.md"

	logic_mod.append_to_history(cancelled_path, "Cancelled", current_month, { task })
	vim.notify("Task cancelled and moved to cancelled.md", vim.log.levels.INFO)
end

function M.split_current_task()
	require("gtodo-md.split").split_current_task()
end

function M.assign_wait_tag(is_visual)
	local bufnr = vim.api.nvim_get_current_buf()
	local start_row, end_row
	if is_visual then
		start_row = vim.fn.line("'<")
		end_row = vim.fn.line("'>")
	else
		start_row = vim.fn.line(".")
		end_row = start_row
	end

	-- 1. 非同期待機中の行追跡のためにExtmarksを打つ
	local ns = vim.api.nvim_create_namespace("gtodo_wait_assign")
	local marks = {}
	for row = start_row, end_row do
		local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {})
		table.insert(marks, mark_id)
	end

	-- 2. プロンプトを開く
	vim.ui.input({ prompt = "Waiting for (empty to remove): " }, function(input)
		-- 非同期コールバック
		if not input then
			-- aborted
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
			return
		end

		input = vim.trim(input)
		local lines_to_update = {}

		for _, mark_id in ipairs(marks) do
			local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark_id, {})
			if pos and pos[1] then
				local r = pos[1]
				local line = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1]
				local task = task_mod.parse(line)
				if task then
					if input == "" then
						task.wait = nil
					else
						task.wait = input
					end
					local new_line = task_mod.serialize(task)
					table.insert(lines_to_update, { row = r, text = new_line })
				end
			end
		end

		-- Extmarkの掃除
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

		if #lines_to_update == 0 then
			return
		end

		-- 3. 一括でバッファを更新し、undo履歴を連結する
		local ok, err = pcall(function()
			vim.cmd("undojoin")
			for _, update in ipairs(lines_to_update) do
				vim.api.nvim_buf_set_lines(bufnr, update.row, update.row + 1, false, { update.text })
			end
		end)

		-- もし undojoin が直前の変更がないという理由で失敗した場合のフォールバック
		if not ok and err and tostring(err):match("E790") then
			for _, update in ipairs(lines_to_update) do
				vim.api.nvim_buf_set_lines(bufnr, update.row, update.row + 1, false, { update.text })
			end
		end

		-- 保存
		pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent! write")
		end)
	end)
end

return M
