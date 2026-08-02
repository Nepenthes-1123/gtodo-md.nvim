local M = {}
local config = require("gtodo-md.config")
local ui_mod = require("gtodo-md.ui")
local io_mod = require("gtodo-md.io")
local logic_mod = require("gtodo-md.logic")
local editor_mod = require("gtodo-md.editor")
local timer_mod = require("gtodo-md.timer")
local lock_mod = require("gtodo-md.lock")
local autocmds_mod = require("gtodo-md.autocmds")

function M.setup(opts)
	config.setup(opts)

	-- ディレクトリ内のデフォルトファイルを用意する
	io_mod.ensure_files()

	-- 起動時に日付変更チェックを走らせる（Dashboard等への最新データ提供のため）
	require("gtodo-md.daily").check_daily_rollover()

	-- タイマー開始
	timer_mod.start_waiting_timer()
	timer_mod.start_daily_rollover_timer()

	-- Autocmdの設定
	M.setup_autocmds()
	require("gtodo-md.highlight").setup()

	-- グローバルキーマップの設定
	if config.get("use_default_keymaps") then
		M.setup_global_keymaps()
	end

	-- ユーザーコマンドの登録
	vim.api.nvim_create_user_command("GtodoQueue", function()
		ui_mod.open_queue()
	end, { desc = "Open Gtodo Queue view" })
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

	local daily_mod = require("gtodo-md.daily")

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
	lock_mod.with_write_lock(data_dir, function()
		logic_mod.check_dues(inbox_path, todo_path)
		if filename == "todo.md" then
			logic_mod.sort_todo_file(todo_path)
		end
	end)

	-- バッファローカルキーマップを登録
	if config.get("use_default_keymaps") then
		M.setup_buffer_keymaps(bufnr)
	end

	-- 構文ハイライトのアタッチ
	require("gtodo-md.highlight").attach(bufnr)

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
			require("gtodo-md.ui.prompt").prompt_task(task, function(updated_task)
				if not vim.api.nvim_buf_is_valid(target_buf) then
					return
				end
				local newline = require("gtodo-md.task").serialize(updated_task)
				-- ポップアップ編集中に裏側でソートが走り行番号がズレる対策（文字一致で現在行を再探査）
				local target_row = nil
				if old_line then
					local normalized_old_line = require("gtodo-md.task").serialize(task)
					local current_lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
					for i, l in ipairs(current_lines) do
						if l == old_line or l == normalized_old_line then
							target_row = i
							break
						end
					end
				end
				target_row = target_row or row

				vim.api.nvim_buf_set_lines(target_buf, target_row - 1, target_row, false, { newline })
				vim.api.nvim_buf_call(target_buf, function()
					vim.cmd("silent! write")
				end)
				if filename == "todo.md" then
					local changed = false
					lock_mod.with_write_lock(data_dir, function()
						changed = logic_mod.check_dues(inbox_path, todo_path)
						logic_mod.sort_todo_file(todo_path)
					end)
					if changed and not vim.bo[target_buf].modified then
						require("gtodo-md.daily").reload_managed_bufs()
					end
				else
					local changed = false
					lock_mod.with_write_lock(data_dir, function()
						changed = logic_mod.check_dues(inbox_path, todo_path)
						if changed then
							logic_mod.sort_todo_file(todo_path)
						end
					end)
					if changed and not vim.bo[target_buf].modified then
						require("gtodo-md.daily").reload_managed_bufs()
					end
				end
			end)
			return
		end
	end

	-- 新規追加
	require("gtodo-md.ui.prompt").prompt_task(nil, function(new_task)
		local cb_bufname = vim.api.nvim_buf_get_name(target_buf)
		local cb_filename = vim.fn.fnamemodify(cb_bufname, ":t")

		-- 提案B: todo.md内で新規追加された場合でも、未来期日なら未整理としてInboxへルーティングする
		if cb_filename == "todo.md" and new_task.due and new_task.due ~= "" then
			local today = os.date("%Y-%m-%d")
			if new_task.due > today then
				cb_filename = "inbox.md"
			end
		end

		if cb_filename == "todo.md" then
			local target_sec = editor_mod.get_current_section()
			if target_sec == "default" then
				target_sec = config.sections.TODAY
			end

			local todo_data = io_mod.read_todo_file(todo_path)
			if not todo_data.sections[target_sec] then
				todo_data.sections[target_sec] = {}
			end
			table.insert(todo_data.sections[target_sec], { type = "task", task = new_task })
			io_mod.write_todo_file(todo_path, todo_data)
			lock_mod.with_write_lock(data_dir, function()
				logic_mod.sort_todo_file(todo_path)
			end)

			-- reload open buffers if not modified
			if not timer_mod.should_skip_timer() then
				require("gtodo-md.daily").reload_managed_bufs()
			end
		else
			-- inbox.md (またはその他) で追加された場合は inbox に留める
			local inbox_data = io_mod.read_todo_file(inbox_path)
			if not inbox_data.sections["default"] then
				inbox_data.sections["default"] = {}
			end

			local sec_items = inbox_data.sections["default"]
			while
				#sec_items > 0
				and sec_items[#sec_items].type == "text"
				and vim.trim(sec_items[#sec_items].line) == ""
			do
				table.remove(sec_items)
			end

			table.insert(sec_items, { type = "task", task = new_task })
			io_mod.write_todo_file(inbox_path, inbox_data)

			lock_mod.with_write_lock(data_dir, function()
				local changed = logic_mod.check_dues(inbox_path, todo_path)
				if changed then
					logic_mod.sort_todo_file(todo_path)
				end
			end)

			-- reload open buffers if not modified
			if not timer_mod.should_skip_timer() then
				require("gtodo-md.daily").reload_managed_bufs()
			end
			if filename ~= "inbox.md" then
				vim.notify("Created new task in inbox.md", vim.log.levels.INFO)
			end
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
	lock_mod.with_write_lock(data_dir, function()
		logic_mod.check_dues(inbox_path, todo_path)
		logic_mod.sort_todo_file(todo_path)
	end)
end

-- グローバルキーマップの設定
function M.setup_global_keymaps()
	local prefix = config.get("keymap_prefix")

	-- 表示系
	vim.keymap.set("n", prefix .. "t", function()
		ui_mod.open_todo_float()
	end, { desc = "Toggle Todo float" })
	vim.keymap.set("n", prefix .. "i", function()
		ui_mod.open_inbox_float()
	end, { desc = "Toggle Inbox float" })

	-- 表示系 (履歴)
	vim.keymap.set("n", prefix .. "hd", function()
		ui_mod.open_done_float()
	end, { desc = "Toggle Done float" })
	vim.keymap.set("n", prefix .. "hc", function()
		ui_mod.open_cancelled_float()
	end, { desc = "Toggle Cancelled float" })

	-- 検索
	vim.keymap.set("n", prefix .. "/", function()
		ui_mod.search_tasks()
	end, { desc = "Search tasks" })

	-- 追加・編集系 (適応的)
	vim.keymap.set("n", prefix .. "a", function()
		M.add_or_edit_task()
	end, { desc = "Add or edit task" })

	-- Queue ビュー
	vim.keymap.set("n", prefix .. "q", function()
		ui_mod.open_queue()
	end, { desc = "Open Queue view" })
end

-- バッファローカルなキーマップを設定する
function M.setup_buffer_keymaps(bufnr)
	local prefix = config.get("keymap_prefix")
	local function map(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
	end

	-- 移動系
	map("n", prefix .. "d", function()
		editor_mod.move_current_task_to(config.sections.TODAY)
	end, "Move task to " .. config.sections.TODAY)
	map("n", prefix .. "n", function()
		editor_mod.move_current_task_to(config.sections.NEXT)
	end, "Move task to " .. config.sections.NEXT)
	map("n", prefix .. "w", function()
		editor_mod.move_current_task_to(config.sections.WAITING)
	end, "Move task to " .. config.sections.WAITING)
	map("n", prefix .. "tw", function()
		editor_mod.assign_wait_tag(false)
	end, "Assign wait: tag")
	map("v", prefix .. "tw", function()
		editor_mod.assign_wait_tag(true)
	end, "Assign wait: tag to selection")
	map("n", prefix .. "s", function()
		editor_mod.move_current_task_to(config.sections.SOMEDAY)
	end, "Move task to " .. config.sections.SOMEDAY)

	map("n", prefix .. "x", function()
		editor_mod.toggle_complete()
	end, "Toggle task completion")
	map("n", prefix .. "c", function()
		editor_mod.cancel_current_task()
	end, "Cancel task")

	-- タスク分割・プロジェクト化 (Issue #22)
	map("n", prefix .. "p", function()
		editor_mod.split_current_task()
	end, "Split / Promote task")

	-- ジャンプ系
	map("n", prefix .. "jp", function()
		ui_mod.jump_to_project()
	end, "Jump to project file")

	-- 機能系
	map("n", prefix .. "o", function()
		M.sort_and_check_dues()
	end, "Sort and check due dates")
end

return M
