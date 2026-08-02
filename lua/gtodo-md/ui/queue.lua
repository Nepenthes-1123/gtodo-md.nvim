local M = {}
local config = require("gtodo-md.config")
local utils = require("gtodo-md.utils")
local float_ui = require("gtodo-md.ui.float")

local WEEKDAYS_JP = { "日", "月", "火", "水", "木", "金", "土" }
local SEPARATOR = string.rep("─", 46)

-- ファイルをバッファとして読み込む。
-- 既にロード済みならそのまま返す(何もイベントは発火しない)。
-- 未ロードの場合、bufload() は BufRead/BufReadPre/BufReadPost 等の
-- autocmdを発火させ、それが handle_buf_enter 相当の自動処理(due チェック等)を
-- Queue を開くたびに誤って再発火させてしまう(#93)。一時的に該当イベントを
-- 抑制することでこれを防ぐ。
--
-- また、この読み込みはQueue表示用の一時的なものであり編集を伴わないため、
-- swapfile によるクラッシュ復旧保護は不要。同じファイルを別ウィンドウで
-- 既に編集中の場合の "swap file already exists" 警告や、(まれに)swapファイル
-- 用ディレクトリ作成の競合を避けるため無効化しておく。
local function load_buf_quietly(filepath)
	local buf = vim.fn.bufadd(filepath)
	if vim.api.nvim_buf_is_loaded(buf) then
		return buf
	end

	vim.bo[buf].swapfile = false

	local prev_eventignore = vim.o.eventignore
	vim.o.eventignore = "BufRead,BufReadPre,BufReadPost,BufEnter,FileType"
	local ok, err = pcall(vim.fn.bufload, buf)
	vim.o.eventignore = prev_eventignore

	if not ok then
		error(err, 0)
	end
	return buf
end
M._load_buf_quietly = load_buf_quietly

-- 「今日」の日付文字列。純関数のデフォルト引数用。
local function default_today_str()
	return os.date("%Y-%m-%d")
end

--- データ収集 ---------------------------------------------------------------

-- 行が Queue の表示対象かどうかを判定する(純関数)。
-- 対象ならパース済みの task を、そうでなければ nil を返す。
function M._match_queue_task(line, mode)
	local task = require("gtodo-md.task").parse(line)
	if task and task.status ~= "x" then
		if (mode == "due" and task.due) or (mode == "wait" and task.wait) then
			return task
		end
	end
	return nil
end

-- inbox.md と todo.md を走査して対象タスクのエントリを集める。
-- ジャンプ先の追跡用に、元バッファへ extmark を設置する。
local function collect_entries(mode, ns)
	local data_dir = config.get("data_dir")
	local source_files = {
		data_dir .. "/inbox.md",
		data_dir .. "/todo.md",
	}

	local entries = {}

	for _, filepath in ipairs(source_files) do
		if vim.fn.filereadable(filepath) == 1 then
			local buf = load_buf_quietly(filepath)
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			for lnum, line in ipairs(lines) do
				local task = M._match_queue_task(line, mode)
				if task then
					local mark_id = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {})
					table.insert(
						entries,
						{ task = task, filepath = filepath, lnum = lnum, mark_id = mark_id, bufnr = buf }
					)
				end
			end
		end
	end

	return entries
end

--- グルーピングとソート -----------------------------------------------------

-- 収集済みエントリを表示グループへ振り分け、表示順へソートする(純関数)。
-- entries: { { task=..., filepath=..., lnum=..., mark_id=..., bufnr=... }, ... }
-- today_time: 「今日」の 00:00 を指すエポック秒(省略時は実際の今日)
-- 戻り値: { overdue, by_date, sorted_dates, later, by_person, sorted_persons }
function M._group_entries(entries, mode, today_time)
	today_time = today_time or utils.date_to_time(default_today_str())
	local week_end_time = today_time + 7 * 24 * 60 * 60

	-- due モード用のグループ分け
	local overdue = {}
	local by_date = {}
	local later = {}

	-- wait モード用のグループ分け
	local by_person = {}

	for _, entry in ipairs(entries) do
		if mode == "due" then
			local due_time = utils.date_to_time(entry.task.due)
			if due_time < today_time then
				table.insert(overdue, entry)
			elseif due_time <= week_end_time then
				if not by_date[entry.task.due] then
					by_date[entry.task.due] = {}
				end
				table.insert(by_date[entry.task.due], entry)
			else
				table.insert(later, entry)
			end
		else
			-- wait モード
			local person = entry.task.wait
			if not by_person[person] then
				by_person[person] = {}
			end
			table.insert(by_person[person], entry)
		end
	end

	-- ソート
	local sorted_dates = {}
	local sorted_persons = {}

	if mode == "due" then
		for d in pairs(by_date) do
			table.insert(sorted_dates, d)
		end
		table.sort(sorted_dates)
		table.sort(overdue, function(a, b)
			return a.task.due < b.task.due
		end)
		table.sort(later, function(a, b)
			return a.task.due < b.task.due
		end)
	else
		for p in pairs(by_person) do
			table.insert(sorted_persons, p)
		end
		table.sort(sorted_persons)
	end

	return {
		overdue = overdue,
		by_date = by_date,
		sorted_dates = sorted_dates,
		later = later,
		by_person = by_person,
		sorted_persons = sorted_persons,
	}
end

--- 表示行の生成 -------------------------------------------------------------

local function task_line(entry, prefix)
	local task = entry.task
	local line = (prefix or "  ▶ ") .. task.content
	if task.project then
		line = line .. " +" .. task.project
	end
	if task.context then
		line = line .. " " .. task.context
	end
	return line
end

local function date_label(date_str, today_time)
	local t = utils.date_to_time(date_str)
	local diff = math.floor((t - today_time) / 86400)
	local mo = tonumber(date_str:sub(6, 7))
	local d = tonumber(date_str:sub(9, 10))
	local wday = tonumber(os.date("%w", t)) + 1
	local wd = WEEKDAYS_JP[wday]
	if diff == 0 then
		return string.format(" 今日 (%d/%d %s)", mo, d, wd), "DiagnosticWarn"
	elseif diff == 1 then
		return string.format(" 明日 (%d/%d %s)", mo, d, wd), "DiagnosticInfo"
	else
		return string.format(" %d/%d %s (%d日後)", mo, d, wd, diff), "DiagnosticInfo"
	end
end

-- エントリからジャンプ先情報(line_map の値)を作る。
local function source_of(entry)
	return {
		filepath = entry.filepath,
		original_line = entry.task.original_line,
		lnum = entry.lnum,
		mark_id = entry.mark_id,
		bufnr = entry.bufnr,
	}
end

-- グルーピング済みデータから表示行を組み立てる(純関数)。
-- 戻り値:
--   lines    表示するバッファ行のリスト
--   hls      { line_idx(0-based), hl_group } のリスト
--   line_map line_idx(0-based) -> { filepath, original_line, lnum, mark_id, bufnr }
function M._build_display(mode, groups, today_str, today_time)
	today_str = today_str or default_today_str()
	today_time = today_time or utils.date_to_time(today_str)

	local lines = {}
	local hls = {}
	local line_map = {}

	local function add(text, hl_group, source)
		table.insert(lines, text)
		local idx = #lines - 1
		if hl_group then
			table.insert(hls, { idx, hl_group })
		end
		if source then
			line_map[idx] = source
		end
	end

	local sep = SEPARATOR

	-- ヘッダー
	if mode == "due" then
		add(" Queue (Due)  " .. today_str, "Title")
	else
		add(" Queue (Wait) " .. today_str, "Title")
	end
	add(sep, "Comment")

	if mode == "due" then
		-- 期限切れ
		if #groups.overdue > 0 then
			add("", nil)
			add(" 期限切れ", "DiagnosticError")
			add(sep, "Comment")
			for _, entry in ipairs(groups.overdue) do
				local days_over = math.floor((today_time - utils.date_to_time(entry.task.due)) / 86400)
				add(
					task_line(entry, "  ⚠ ") .. string.format(" (%d日超過)", days_over),
					"DiagnosticError",
					source_of(entry)
				)
			end
		end
		-- 今日〜7日後（タスクある日のみ）
		for _, date in ipairs(groups.sorted_dates) do
			local label, hl = date_label(date, today_time)
			add("", nil)
			add(label, hl)
			add(sep, "Comment")
			for _, entry in ipairs(groups.by_date[date]) do
				add(task_line(entry), nil, source_of(entry))
			end
		end

		-- それ以降
		if #groups.later > 0 then
			add("", nil)
			add(" それ以降", "Comment")
			add(sep, "Comment")
			for _, entry in ipairs(groups.later) do
				local mo = tonumber(entry.task.due:sub(6, 7))
				local d = tonumber(entry.task.due:sub(9, 10))
				add(task_line(entry) .. string.format("  due:%d/%d", mo, d), "Comment", source_of(entry))
			end
		end

		-- タスクがひとつもない場合
		if #groups.overdue == 0 and #groups.sorted_dates == 0 and #groups.later == 0 then
			add("", nil)
			add("  期限付きタスクはありません", "DiagnosticOk")
		end
	else
		-- wait モードの表示
		for _, person in ipairs(groups.sorted_persons) do
			add("", nil)
			add(" " .. person .. " 待ち", "DiagnosticWarn")
			add(sep, "Comment")
			for _, entry in ipairs(groups.by_person[person]) do
				add(task_line(entry), nil, source_of(entry))
			end
		end

		if #groups.sorted_persons == 0 then
			add("", nil)
			add("  誰かの作業を待っているタスクはありません", "DiagnosticOk")
		end
	end

	return lines, hls, line_map
end

--- UI(バッファ/ウィンドウ/キーマップ) --------------------------------------

-- Queue ビュー: due または wait 付き未完了タスクを表示する
-- mode: "due" (デフォルト) または "wait"
function M.open_queue(mode, previous_target_id)
	mode = mode or "due"

	local ns = vim.api.nvim_create_namespace("gtodo_queue_marks")
	local entries = collect_entries(mode, ns)

	local today_str = os.date("%Y-%m-%d")
	local today_time = utils.date_to_time(today_str)

	local groups = M._group_entries(entries, mode, today_time)
	local lines, hls, line_map = M._build_display(mode, groups, today_str, today_time)

	-- フローティングウィンドウ
	local width = math.min(math.floor(vim.o.columns * 0.65), 80)
	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
	local col = math.floor((vim.o.columns - width) / 2)
	local row = math.floor((vim.o.lines - height) / 2)

	-- 既存のgtodoフロートを閉じてから Queue を開く
	float_ui.close_current_float()

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"

	local ok, queue_win = pcall(vim.api.nvim_open_win, buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = " Queue ",
		title_pos = "center",
	})

	if not ok or not queue_win then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		vim.notify("Failed to open Queue window. Terminal size might be too small.", vim.log.levels.ERROR)
		return
	end

	float_ui.register_float_win(queue_win)

	-- ハイライト適用
	local hl_ns = vim.api.nvim_create_namespace("gtodo_queue")
	for _, hl in ipairs(hls) do
		vim.api.nvim_buf_add_highlight(buf, hl_ns, hl[2], hl[1], 0, -1)
	end

	-- バッファローカルキーマップ
	vim.keymap.set("n", "q", ":q<CR>", { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Esc>", ":q<CR>", { buffer = buf, noremap = true, silent = true })

	-- Tab: Date view と Wait view をトグルする
	vim.keymap.set("n", "<Tab>", function()
		-- 現在の行のIDを記録 (filepath:lnum)
		local cursor_idx = vim.api.nvim_win_get_cursor(0)[1] - 1
		local current_source = line_map[cursor_idx]
		local target_id = current_source and (current_source.filepath .. ":" .. vim.trim(current_source.original_line))
			or nil

		local next_mode = mode == "due" and "wait" or "due"
		vim.schedule(function()
			M.open_queue(next_mode, target_id)
		end)
	end, { buffer = buf, noremap = true, silent = true })

	-- Enter: カーソル行のタスクのファイル・行へジャンプ
	vim.keymap.set("n", "<CR>", function()
		local cursor_idx = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-based
		local source = line_map[cursor_idx]
		if not source then
			return
		end

		-- Queue ウィンドウを閉じてフローティングでファイルを開き該当行へ移動
		vim.cmd("q")
		local fname = vim.fn.fnamemodify(source.filepath, ":t:r"):upper()
		local new_buf, new_win = float_ui.open_float(source.filepath, fname)

		local new_lnum = nil
		if source.mark_id and source.bufnr and vim.api.nvim_buf_is_valid(source.bufnr) then
			local pos = vim.api.nvim_buf_get_extmark_by_id(source.bufnr, ns, source.mark_id, {})
			if pos and pos[1] then
				new_lnum = pos[1] + 1
			end
		end

		-- Extmarkがバッファ全置換で消失した場合、行の完全一致でフォールバック検索する
		if not new_lnum and source.original_line and new_buf then
			local lines_in_buf = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
			for i, l in ipairs(lines_in_buf) do
				if vim.trim(l) == vim.trim(source.original_line) then
					new_lnum = i
					break
				end
			end
		end

		new_lnum = new_lnum or source.lnum

		if new_lnum then
			pcall(vim.api.nvim_win_set_cursor, new_win, { new_lnum, 0 })
		end
	end, { buffer = buf, noremap = true, silent = true })

	-- もし前のビューから引き継いだターゲットがあれば復元
	if previous_target_id then
		for idx, source in pairs(line_map) do
			if source and (source.filepath .. ":" .. vim.trim(source.original_line)) == previous_target_id then
				pcall(vim.api.nvim_win_set_cursor, queue_win, { idx + 1, 0 })
				break
			end
		end
	end
end

return M
