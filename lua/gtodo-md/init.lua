local M = {}
local config = require("gtodo-md.config")
local ui_mod = require("gtodo-md.ui")
local io_mod = require("gtodo-md.io")
local logic_mod = require("gtodo-md.logic")
local editor_mod = require("gtodo-md.editor")
local timer_mod = require("gtodo-md.timer")
local utils_mod = require("gtodo-md.utils")

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
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local filename = vim.fn.fnamemodify(bufname, ":t")

	if filename ~= "inbox.md" and filename ~= "todo.md" then
		return
	end

	local data_dir = config.get("data_dir")
	local inbox_path = data_dir .. "/inbox.md"
	local todo_path = data_dir .. "/todo.md"

	local daily_mod = require("gtodo-md.daily")

	-- 全 gtodo バッファの中に未保存編集中のものが1つでも存在するかチェック
	local has_modified_gtodo = false
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
			local bname = vim.api.nvim_buf_get_name(buf)
			if utils_mod.is_gtodo_file(bname) then
				has_modified_gtodo = true
				break
			end
		end
	end

	-- 未保存バッファが存在する場合は、ディスク更新によるデータ上書き消失を避けるため
	-- check_daily_rollover も含めたディスク自動更新をすべてスキップ
	if has_modified_gtodo then
		if config.get("use_default_keymaps") then
			M.setup_buffer_keymaps(bufnr)
		end
		return
	end

	-- 1. 安全な状態（未保存なし）でのみ大掃除・日付変更チェックを実行
	daily_mod.check_daily_rollover()

	local current_inbox_mtime = vim.fn.getftime(inbox_path)
	local current_todo_mtime = vim.fn.getftime(todo_path)

	-- スキップ判定
	local skip_process = true
	local cached_mtimes = daily_mod.get_cache()
	if current_inbox_mtime ~= cached_mtimes.inbox then
		skip_process = false
	elseif current_todo_mtime ~= cached_mtimes.todo then
		skip_process = false
	end

	if skip_process then
		-- 重い自動処理はスキップするが、キーマップ登録だけは毎回行う
		if config.get("use_default_keymaps") then
			M.setup_buffer_keymaps(bufnr)
		end
		return
	end

	-- 2. dueチェック・自動移動
	logic_mod.check_dues(inbox_path, todo_path)

	-- 3. 自動ソート（todo.mdのみ）
	if filename == "todo.md" then
		logic_mod.sort_todo_file(todo_path)
	end

	-- バッファローカルキーマップを登録
	if config.get("use_default_keymaps") then
		M.setup_buffer_keymaps(bufnr)
	end

	-- 構文ハイライトのアタッチ
	require("gtodo-md.highlight").attach(bufnr)

	-- gtodo-md 対象バッファに autoread を設定
	vim.bo[bufnr].autoread = true

	-- 自動処理によってディスク上のファイルが変更された場合、未保存の変更がなければバッファを同期（リロード）する
	if not vim.bo[bufnr].modified then
		vim.cmd("checktime")
	end

	-- キャッシュを最新化
	daily_mod.update_cache(vim.fn.getftime(inbox_path), vim.fn.getftime(todo_path))
end

function M.setup_autocmds()
	local group = vim.api.nvim_create_augroup("GtodoMd", { clear = true })

	-- この setup_autocmds 実行インスタンスに完全にカプセル化されたキャッシュテーブル
	-- augroup のクリア (clear = true) と連動して再初期化されるため、古い Autocmd との不整合は起きない
	local original_created_dates = {}
	local original_history_sections = {}

	-- todo.md 保存時のバリデーション
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = group,
		pattern = { "todo.md" },
		callback = function(args)
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local required =
				{ config.sections.TODAY, config.sections.NEXT, config.sections.WAITING, config.sections.SOMEDAY }
			local found = {
				Today = false,
				Next = false,
				Waiting = false,
				Someday = false,
			}

			for _, line in ipairs(lines) do
				local sec = line:match("^##%s+(.*)$")
				if sec then
					sec = vim.trim(sec)
					if found[sec] ~= nil then
						found[sec] = true
					end
				end
			end

			local missing = {}
			for _, sec in ipairs(required) do
				if not found[sec] then
					table.insert(missing, "## " .. sec)
				end
			end

			if #missing > 0 then
				local msg = "[gtodo-md] 必須セクションが不足しているため保存を中断しました ("
					.. table.concat(missing, ", ")
					.. ") ※スタックトレースは仕様です"
				-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
				-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
				error(msg, 0)
			end
		end,
	})

	-- done.md, cancelled.md ロード/表示時に既存の年月セクション見出しをキャッシュする
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = group,
		pattern = { "done.md", "cancelled.md" },
		callback = function(args)
			if original_history_sections[tostring(args.buf)] then
				return
			end

			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local original_secs = {}
			for _, line in ipairs(lines) do
				local sec = line:match("^##%s+(%d%d%d%d%-%d%d)$")
				if sec then
					original_secs[sec] = true
				end
			end
			original_history_sections[tostring(args.buf)] = original_secs
		end,
	})

	-- inbox.md, done.md, cancelled.md 保存時のヘッダー保護
	local history_patterns = {
		["inbox.md"] = "# Inbox",
		["done.md"] = "# Done",
		["cancelled.md"] = "# Cancelled",
	}

	for fname, expected_header in pairs(history_patterns) do
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = group,
			pattern = fname,
			callback = function(args)
				local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
				local has_header = false
				for _, line in ipairs(lines) do
					if line:match("^" .. expected_header) then
						has_header = true
						break
					end
				end

				if not has_header then
					local msg = string.format(
						"[gtodo-md] 必須ヘッダー (%s) が削除されたため保存を中断しました ※スタックトレースは仕様です",
						expected_header
					)
					-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
					-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
					error(msg, 0)
				end

				-- 年月セクションの削除保護 (done.md と cancelled.md のみ)
				if fname == "done.md" or fname == "cancelled.md" then
					local original_secs = original_history_sections[tostring(args.buf)] or {}
					local found_secs = {}
					for _, line in ipairs(lines) do
						local sec = line:match("^##%s+(%d%d%d%d%-%d%d)$")
						if sec then
							found_secs[sec] = true
						end
					end

					local missing_secs = {}
					for sec, _ in pairs(original_secs) do
						if not found_secs[sec] then
							table.insert(missing_secs, "## " .. sec)
						end
					end

					if #missing_secs > 0 then
						local msg = string.format(
							"[gtodo-md] 既存の履歴セクション (%s) が削除されたため保存を中断しました ※スタックトレースは仕様です",
							table.concat(missing_secs, ", ")
						)
						-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
						-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
						error(msg, 0)
					end
				end
			end,
		})
	end

	-- projects/*.md ロード/表示時に created の値とフロントマターをキャッシュする
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = group,
		pattern = { "*/projects/*.md" },
		callback = function(args)
			if original_created_dates[tostring(args.buf)] then
				return
			end

			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			if #lines > 0 and lines[1] == "---" then
				local end_idx = nil
				for i = 2, #lines do
					if lines[i] == "---" then
						end_idx = i
						break
					end
				end

				if end_idx then
					for i = 2, end_idx - 1 do
						local line = lines[i]
						local created_val = line:match("^created:%s*(.*)$")
						if created_val then
							original_created_dates[tostring(args.buf)] = vim.trim(created_val)
							break
						end
					end
				end
			end
		end,
	})

	-- projects/*.md 保存時のフロントマター保護
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = group,
		pattern = { "*/projects/*.md" },
		callback = function(args)
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local filepath = args.match
			local proj_name = vim.fn.fnamemodify(filepath, ":t:r")

			-- フロントマター検証
			local valid_frontmatter = false
			local created_changed = false
			local tag_matches_filename = false
			local required_keys = {
				title = false,
				tag = false,
				created = false,
				due = false,
				status = false,
				members = false,
			}

			if #lines > 0 and lines[1] == "---" then
				local end_idx = nil
				for i = 2, #lines do
					if lines[i] == "---" then
						end_idx = i
						break
					end
				end

				if end_idx then
					for i = 2, end_idx - 1 do
						local line = lines[i]
						local key, val = line:match("^(%w+):%s*(.*)$")
						if key then
							if required_keys[key] ~= nil then
								required_keys[key] = true
							end
							val = vim.trim(val or "")
							if key == "tag" and val == proj_name then
								tag_matches_filename = true
							elseif key == "created" then
								local original_created = original_created_dates[tostring(args.buf)]
								if original_created and val ~= original_created then
									created_changed = true
								end
							end
						end
					end

					local missing_keys = {}
					for k, found in pairs(required_keys) do
						if not found then
							table.insert(missing_keys, k)
						end
					end

					if #missing_keys == 0 and tag_matches_filename and not created_changed then
						valid_frontmatter = true
					end
				end
			end

			if not valid_frontmatter then
				local errors = {}
				if created_changed then
					table.insert(errors, "created (作成日) の変更は禁止されています")
				end
				if not tag_matches_filename then
					table.insert(
						errors,
						string.format("tag の値がファイル名 (%s) と一致していません", proj_name)
					)
				end

				local missing_keys = {}
				for k, found in pairs(required_keys) do
					if not found then
						table.insert(missing_keys, k)
					end
				end
				if #missing_keys > 0 then
					table.insert(
						errors,
						"必須項目が不足しています (" .. table.concat(missing_keys, ", ") .. ")"
					)
				end

				if #errors == 0 then
					table.insert(errors, "フロントマターのフォーマット (---) が破損しています")
				end

				local msg = "[gtodo-md] フロントマターが不正なため保存を中断しました ("
					.. table.concat(errors, " / ")
					.. ") ※スタックトレースは仕様です"
				-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
				-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
				error(msg, 0)
			end
		end,
	})

	-- バッファが完全にメモリから消去された時のみキャッシュメモリを解放
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		pattern = { "done.md", "cancelled.md", "*/projects/*.md" },
		callback = function(args)
			local bufnr = args.buf
			-- バッファがまだ有効またはロード済みの場合は、誤検知なのでクリアをスキップする！
			if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
				return
			end

			original_history_sections[tostring(bufnr)] = nil
			original_created_dates[tostring(bufnr)] = nil
		end,
	})

	-- gtodo-md 対象バッファへ autoread を設定
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = group,
		pattern = "*",
		callback = function(args)
			if vim.api.nvim_buf_is_valid(args.buf) then
				local bufname = vim.api.nvim_buf_get_name(args.buf)
				if utils_mod.is_gtodo_file(bufname) then
					vim.bo[args.buf].autoread = true
				end
			end
		end,
	})

	-- inbox.md, todo.md 用
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = { "inbox.md", "todo.md" },
		callback = function(args)
			vim.schedule(function()
				M.handle_buf_enter(args.buf)
			end)
		end,
	})

	-- gtodo バッファ保存 (:w) 完了後の自動整理・全バッファ同期再開
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*",
		callback = function(args)
			if vim.api.nvim_buf_is_valid(args.buf) then
				local bufname = vim.api.nvim_buf_get_name(args.buf)
				if utils_mod.is_gtodo_file(bufname) then
					vim.schedule(function()
						M.handle_buf_enter(args.buf)
						-- 他のロード済み未保存なし gtodo バッファも一括 checktime 同期
						for _, buf in ipairs(vim.api.nvim_list_bufs()) do
							if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
								local bname = vim.api.nvim_buf_get_name(buf)
								if utils_mod.is_gtodo_file(bname) then
									vim.api.nvim_buf_call(buf, function()
										vim.cmd("checktime")
									end)
								end
							end
						end
					end)
				end
			end
		end,
	})

	-- フォーカスが戻った時の日付変更検知と全 gtodo バッファの最新一括同期
	vim.api.nvim_create_autocmd("FocusGained", {
		group = group,
		pattern = "*",
		callback = function()
			vim.schedule(function()
				if not timer_mod.should_skip_timer() then
					require("gtodo-md.daily").check_daily_rollover()
					for _, buf in ipairs(vim.api.nvim_list_bufs()) do
						if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
							local bname = vim.api.nvim_buf_get_name(buf)
							if utils_mod.is_gtodo_file(bname) then
								vim.api.nvim_buf_call(buf, function()
									vim.cmd("checktime")
								end)
							end
						end
					end
				end
			end)
		end,
	})

	-- 構文ハイライトのアタッチ
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "FileChangedShellPost" }, {
		group = group,
		pattern = "*.md",
		callback = function(ev)
			local bufname = vim.api.nvim_buf_get_name(ev.buf)
			local data_dir = require("gtodo-md.config").get("data_dir")
			if data_dir and bufname:find(data_dir, 1, true) then
				require("gtodo-md.highlight").attach(ev.buf)
			end
		end,
	})

	-- 言語変更時の即時反映のため、データディレクトリ内の.mdでBufEnter時にハイライトを更新
	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		group = group,
		pattern = "*.md",
		callback = function(args)
			local bufname = vim.api.nvim_buf_get_name(args.buf)
			local data_dir = require("gtodo-md.config").get("data_dir")
			if data_dir and bufname:find(data_dir, 1, true) then
				vim.schedule(function()
					require("gtodo-md.highlight").update_highlights(args.buf)
				end)
			end
		end,
	})

	-- projects/*.md 用 (仮想テキストの描画)
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		group = group,
		pattern = "*.md",
		callback = function(args)
			if vim.api.nvim_buf_is_valid(args.buf) then
				local bufname = vim.api.nvim_buf_get_name(args.buf)
				if require("gtodo-md.utils").is_gtodo_file(bufname) and bufname:find("projects") then
					vim.schedule(function()
						require("gtodo-md.ui").render_project_tasks(args.buf)
					end)
				end
			end
		end,
	})

	-- todo.md/inbox.md 保存時に、現在開いている全プロジェクトバッファの仮想テキストを更新する
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "inbox.md", "todo.md" },
		callback = function()
			vim.schedule(function()
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_loaded(buf) then
						require("gtodo-md.ui").render_project_tasks(buf)
					end
				end
			end)
		end,
	})
end

-- 適応的なタスクの追加または編集 (外部呼び出し可能)
function M.add_or_edit_task()
	local bufname = vim.api.nvim_buf_get_name(0)
	local filename = vim.fn.fnamemodify(bufname, ":t")
	local data_dir = config.get("data_dir")
	local inbox_path = data_dir .. "/inbox.md"
	local todo_path = data_dir .. "/todo.md"

	if filename == "todo.md" or filename == "inbox.md" then
		local task, row, old_line = editor_mod.get_current_task()
		if task then
			-- 編集
			require("gtodo-md.ui.prompt").prompt_task(task, function(updated_task)
				local newline = require("gtodo-md.task").serialize(updated_task)
				-- ポップアップ編集中に裏側でソートが走り行番号がズレる対策（文字一致で現在行を再探査）
				local target_row = nil
				if old_line then
					local normalized_old_line = require("gtodo-md.task").serialize(task)
					local current_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
					for i, l in ipairs(current_lines) do
						if l == old_line or l == normalized_old_line then
							target_row = i
							break
						end
					end
				end
				target_row = target_row or row

				vim.api.nvim_buf_set_lines(0, target_row - 1, target_row, false, { newline })
				vim.cmd("silent! write")
				if filename == "todo.md" then
					local changed = logic_mod.check_dues(inbox_path, todo_path)
					logic_mod.sort_todo_file(todo_path)
					if changed and not vim.bo[0].modified then
						vim.cmd("checktime")
					end
				else
					local changed = logic_mod.check_dues(inbox_path, todo_path)
					if changed then
						logic_mod.sort_todo_file(todo_path)
						if not vim.bo[0].modified then
							vim.cmd("checktime")
						end
					end
				end
			end)
			return
		end
	end

	-- 新規追加
	require("gtodo-md.ui.prompt").prompt_task(nil, function(new_task)
		local cb_bufname = vim.api.nvim_buf_get_name(0)
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
				todo_data.sections[target_sec] = { items = {}, subsections = {} }
			end
			table.insert(io_mod.get_section_items(todo_data.sections[target_sec]), { type = "task", task = new_task })
			io_mod.write_todo_file(todo_path, todo_data)
			logic_mod.sort_todo_file(todo_path)

			-- reload open buffers if not modified
			if not timer_mod.should_skip_timer() then
				vim.cmd("checktime")
			end
		else
			-- inbox.md (またはその他) で追加された場合は inbox に留める
			local inbox_data = io_mod.read_todo_file(inbox_path)
			if not inbox_data.sections["default"] then
				inbox_data.sections["default"] = { items = {}, subsections = {} }
			end

			local sec_items = io_mod.get_section_items(inbox_data.sections["default"])
			while
				#sec_items > 0
				and sec_items[#sec_items].type == "text"
				and vim.trim(sec_items[#sec_items].line) == ""
			do
				table.remove(sec_items)
			end

			table.insert(sec_items, { type = "task", task = new_task })
			io_mod.write_todo_file(inbox_path, inbox_data)

			local changed = logic_mod.check_dues(inbox_path, todo_path)
			if changed then
				logic_mod.sort_todo_file(todo_path)
			end

			-- reload open buffers if not modified
			if not timer_mod.should_skip_timer() then
				vim.cmd("checktime")
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
	logic_mod.check_dues(inbox_path, todo_path)
	logic_mod.sort_todo_file(todo_path)
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
