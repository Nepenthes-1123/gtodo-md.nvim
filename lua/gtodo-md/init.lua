local M = {}
local config = require("gtodo-md.config")
local ui_mod = require("gtodo-md.ui")
local io_mod = require("gtodo-md.io")
local logic_mod = require("gtodo-md.logic")
local editor_mod = require("gtodo-md.editor")
local timer_mod = require("gtodo-md.timer")
local lock_mod = require("gtodo-md.lock")
local autocmds_mod = require("gtodo-md.autocmds")
local keymaps_mod = require("gtodo-md.keymaps")
local daily_mod = require("gtodo-md.daily")
local highlight_mod = require("gtodo-md.highlight")
local task_mod = require("gtodo-md.task")
local prompt_mod = require("gtodo-md.ui.prompt")

function M.setup(opts)
	config.setup(opts)

	-- ディレクトリ内のデフォルトファイルを用意する
	io_mod.ensure_files()

	-- 起動時に日付変更チェックを走らせる（Dashboard等への最新データ提供のため）
	daily_mod.check_daily_rollover()

	-- タイマー開始
	timer_mod.start_waiting_timer()
	timer_mod.start_daily_rollover_timer()

	-- Autocmdの設定
	M.setup_autocmds()
	highlight_mod.setup()
	require("gtodo-md.ui.kanban").setup()

	-- グローバルキーマップの設定
	if config.get("use_default_keymaps") then
		M.setup_global_keymaps()
	end

	-- ユーザーコマンドの登録
	vim.api.nvim_create_user_command("GtodoQueue", function()
		ui_mod.open_queue()
	end, { desc = "Open Gtodo Queue view" })

	vim.api.nvim_create_user_command("GtodoKanban", function()
		ui_mod.open_kanban()
	end, { desc = "Open Gtodo Kanban view" })

	vim.api.nvim_create_user_command("GtodoEditTemplate", function()
		ui_mod.edit_template()
	end, { desc = "Edit or create a Gtodo task template" })

	vim.api.nvim_create_user_command("GtodoInsertTemplate", function()
		ui_mod.insert_template()
	end, { desc = "Insert tasks from a Gtodo task template" })
end

-- BufEnter時の自動処理
function M.handle_buf_enter(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end

	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local filename = vim.fn.fnamemodify(bufname, ":t")

	if filename ~= "inbox.md" and filename ~= "todo.md" then
		return
	end

	local data_dir = config.get("data_dir")
	local inbox_path = data_dir .. "/inbox.md"
	local todo_path = data_dir .. "/todo.md"

	-- 1. 日付変更チェック
	daily_mod.check_daily_rollover()

	local current_inbox_mtime = vim.fn.getftime(inbox_path)
	local current_todo_mtime = vim.fn.getftime(todo_path)
	-- #89: mtimeは秒精度のため、1秒以内の連続変更を見逃す可能性がある。
	-- ファイルサイズも補助的に比較することで、その一部を追加で検知する
	-- (同一秒内でサイズも変わらない変更は低確率として引き続き許容する)。
	local current_inbox_size = vim.fn.getfsize(inbox_path)
	local current_todo_size = vim.fn.getfsize(todo_path)

	-- スキップ判定
	-- ディスクのmtimeに変化がなくても、このバッファ自体が未保存(dirty)なら
	-- スキップしない。dirtyな内容はディスクに一度も反映されていない可能性が
	-- あり、mtime比較だけでは検知できないため(R1-2)。
	local skip_process = true
	local cached_mtimes, _, cached_sizes = daily_mod.get_cache()
	if current_inbox_mtime ~= cached_mtimes.inbox then
		skip_process = false
	elseif current_todo_mtime ~= cached_mtimes.todo then
		skip_process = false
	elseif current_inbox_size ~= cached_sizes.inbox then
		skip_process = false
	elseif current_todo_size ~= cached_sizes.todo then
		skip_process = false
	elseif vim.bo[bufnr].modified then
		skip_process = false
	end

	if skip_process then
		-- 重い自動処理はスキップするが、キーマップ登録だけは毎回行う
		if config.get("use_default_keymaps") then
			M.setup_buffer_keymaps(bufnr)
		end
		return
	end

	-- 2. dueチェック・自動移動・自動ソート（todo.mdのみ）を排他ロック配下で実行
	-- バッファが未保存(dirty)でも常に実行・保存する。read_lines がライブバッファの
	-- 内容(未保存分を含む)を読み取るため、ユーザーの未保存編集は失われない。
	lock_mod.with_automation_lock(data_dir, function()
		logic_mod.check_dues_and_sort_when_requested(inbox_path, todo_path, filename == "todo.md")
	end)

	-- バッファローカルキーマップを登録
	if config.get("use_default_keymaps") then
		M.setup_buffer_keymaps(bufnr)
	end

	-- 構文ハイライトのアタッチ
	highlight_mod.attach(bufnr)

	-- 自動処理によってディスク上のファイルが変更された場合、未保存の変更がなければ管理バッファを一括同期（リロード）する
	daily_mod.reload_managed_bufs()

	-- キャッシュを最新化
	local done_path = data_dir .. "/done.md"
	daily_mod.update_cache(
		vim.fn.getftime(inbox_path),
		vim.fn.getftime(todo_path),
		vim.fn.getftime(done_path),
		vim.fn.getfsize(inbox_path),
		vim.fn.getfsize(todo_path),
		vim.fn.getfsize(done_path)
	)
end

-- Autocmd の登録 (実体は autocmds.lua)
function M.setup_autocmds()
	autocmds_mod.setup()
end

-- dueチェックと(必要なら)ソートを排他ロック配下で実行し、check_duesの結果を返す。
-- always_sort は呼び出し元による非対称な仕様を表す:
--   todo.md 側は check_dues の結果に関わらず常にソートする (true)
--   inbox.md 側は変更があったときだけソートする (false)
local function check_dues_and_sort(data_dir, inbox_path, todo_path, always_sort)
	local changed = false
	lock_mod.with_automation_lock(data_dir, function()
		changed = logic_mod.check_dues_and_maybe_sort(inbox_path, todo_path, always_sort)
	end)
	return changed
end

-- 末尾に溜まった空行アイテムを取り除く(追記のたびに空行が増えるのを防ぐ)
local function trim_trailing_blank_items(items)
	while #items > 0 and items[#items].type == "text" and vim.trim(items[#items].line) == "" do
		table.remove(items)
	end
end

-- 指定ファイルの指定セクション末尾へタスクを追記して書き戻す。
-- prepare_items は追記直前に既存アイテム列へ手を入れるための任意のフック。
-- 書き込みに失敗した場合は通知したうえで false を返す(io.write_lines は失敗時に
-- error を投げるが、この経路は lock.with_automation_lock の外側で誰も pcall していない)。
local function append_task_to_file(path, section_name, new_task, prepare_items)
	local data = io_mod.read_todo_file(path)
	local items = data.sections[section_name]
	if not items then
		items = {}
		data.sections[section_name] = items
	end
	if prepare_items then
		prepare_items(items)
	end
	table.insert(items, { type = "task", task = new_task })
	local ok, err = pcall(io_mod.write_todo_file, path, data)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

-- 適応的なタスクの追加または編集 (外部呼び出し可能)
function M.add_or_edit_task()
	local target_buf = vim.api.nvim_get_current_buf()
	local bufname = vim.api.nvim_buf_get_name(target_buf)
	local filename = vim.fn.fnamemodify(bufname, ":t")
	local data_dir = config.get("data_dir")
	local inbox_path = data_dir .. "/inbox.md"
	local todo_path = data_dir .. "/todo.md"

	if filename == "todo.md" or filename == "inbox.md" then
		local task, row, old_line = editor_mod.get_current_task()
		if task then
			-- 編集
			prompt_mod.prompt_task(task, function(updated_task)
				if not vim.api.nvim_buf_is_valid(target_buf) then
					return
				end
				local newline = task_mod.serialize(updated_task)
				-- ポップアップ編集中に裏側でソートが走り行番号がズレる対策（文字一致で現在行を再探査）
				local target_row = nil
				if old_line then
					local normalized_old_line = task_mod.serialize(task)
					local current_lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
					for i, l in ipairs(current_lines) do
						if l == old_line or l == normalized_old_line then
							target_row = i
							break
						end
					end
				end
				target_row = target_row or row

				-- 生の `silent! write` を使ってはならない。io.lua を経由しないため
				-- アトミック置換が掛からないうえ、`silent!` が BufWritePre の検証エラーを
				-- 含む一切の失敗を握り潰す。ユーザーには成功したように見えるがディスクへは
				-- 保存されておらず、次の外部変更リロードで編集内容が静かに失われる。
				local target_path = vim.api.nvim_buf_get_name(target_buf)
				local buf_lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
				if target_row < 1 or target_row > #buf_lines then
					vim.notify("[gtodo-md] The edited line no longer exists.", vim.log.levels.ERROR)
					return
				end
				buf_lines[target_row] = newline
				local write_ok, write_err = pcall(io_mod.write_lines, target_path, buf_lines)
				if not write_ok then
					vim.notify(tostring(write_err), vim.log.levels.ERROR)
					return
				end

				local changed = check_dues_and_sort(data_dir, inbox_path, todo_path, filename == "todo.md")
				if changed and not vim.bo[target_buf].modified then
					daily_mod.reload_managed_bufs()
				end
			end)
			return
		end
	end

	-- 新規追加
	prompt_mod.prompt_task(nil, function(new_task)
		local cb_bufname = vim.api.nvim_buf_get_name(target_buf)
		local cb_filename = vim.fn.fnamemodify(cb_bufname, ":t")

		-- 提案B: todo.md内で新規追加された場合でも、未来期日なら未整理としてInboxへルーティングする
		if cb_filename == "todo.md" and new_task.due and new_task.due ~= "" then
			local today = os.date("%Y-%m-%d")
			if new_task.due > today then
				cb_filename = "inbox.md"
			end
		end

		-- todo.md 以外(inbox.md や無関係なバッファ)からの追加は inbox に留める
		local routed_to_inbox = cb_filename ~= "todo.md"

		if not routed_to_inbox then
			local target_sec = editor_mod.get_current_section()
			if target_sec == "default" then
				target_sec = config.sections.TODAY
			end

			if not append_task_to_file(todo_path, target_sec, new_task) then
				return
			end
			lock_mod.with_automation_lock(data_dir, function()
				logic_mod.sort_todo_file(todo_path)
			end)
		else
			if not append_task_to_file(inbox_path, "default", new_task, trim_trailing_blank_items) then
				return
			end
			check_dues_and_sort(data_dir, inbox_path, todo_path, false)
		end

		-- reload open buffers if not modified
		if not timer_mod.should_skip_timer() then
			daily_mod.reload_managed_bufs()
		end

		-- 追加先が呼び出し元のバッファと異なる場合のみ、行き先を通知する
		if routed_to_inbox and filename ~= "inbox.md" then
			vim.notify("Created new task in inbox.md", vim.log.levels.INFO)
		end
	end)
end

-- 手動ソートと期日チェック (外部呼び出し可能)
function M.sort_and_check_dues()
	local bufname = vim.api.nvim_buf_get_name(0)
	local filename = vim.fn.fnamemodify(bufname, ":t")
	if filename == "inbox.md" then
		return
	end
	local data_dir = config.get("data_dir")
	local inbox_path = data_dir .. "/inbox.md"
	local todo_path = data_dir .. "/todo.md"
	check_dues_and_sort(data_dir, inbox_path, todo_path, true)
end

-- グローバルキーマップの設定 (実体は keymaps.lua)
function M.setup_global_keymaps()
	keymaps_mod.setup_global()
end

-- バッファローカルなキーマップを設定する (実体は keymaps.lua)
function M.setup_buffer_keymaps(bufnr)
	keymaps_mod.setup_buffer(bufnr)
end

return M
