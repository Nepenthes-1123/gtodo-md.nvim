local M = {}
local task_mod = require("gtodo-md.task")
local config = require("gtodo-md.config")

-- 指定されたパスのバッファが存在し、ロードされているか確認
local function get_buf_by_name(path)
	local realpath = vim.fn.fnamemodify(path, ":p")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local bufname = vim.api.nvim_buf_get_name(buf)
			if vim.fn.fnamemodify(bufname, ":p") == realpath then
				return buf
			end
		end
	end
	return nil
end

-- ファイルまたはバッファから行リストを読み込む
function M.read_lines(path)
	local buf = get_buf_by_name(path)
	if buf then
		return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	else
		local lines = {}
		local f = io.open(path, "r")
		if not f then
			return lines
		end
		for line in f:lines() do
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
			end
			table.insert(lines, line)
		end
		f:close()
		return lines
	end
end

function M.format_buffer(bufnr)
	pcall(function()
		if package.loaded["conform"] then
			require("conform").format({ bufnr = bufnr, async = false })
		elseif vim.fn.exists(":Neoformat") == 2 then
			vim.cmd("Neoformat")
		elseif vim.fn.exists(":Format") == 2 then
			vim.cmd("Format")
		else
			vim.lsp.buf.format({ bufnr = bufnr, async = false })
		end
	end)
end

-- 差分のみを更新し、Extmarksの破壊を防ぐ
local function update_lines_incrementally(buf, new_lines)
	local old_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local start_idx = 1
	while start_idx <= #old_lines and start_idx <= #new_lines and old_lines[start_idx] == new_lines[start_idx] do
		start_idx = start_idx + 1
	end

	local end_old = #old_lines
	local end_new = #new_lines
	while end_old >= start_idx and end_new >= start_idx and old_lines[end_old] == new_lines[end_new] do
		end_old = end_old - 1
		end_new = end_new - 1
	end

	if start_idx > #old_lines and start_idx > #new_lines then
		return -- 変更なし
	end

	local replacement = {}
	for i = start_idx, end_new do
		table.insert(replacement, new_lines[i])
	end

	vim.api.nvim_buf_set_lines(buf, start_idx - 1, end_old, false, replacement)
end

-- inbox.md / todo.md への書き込み後、開いているプロジェクトバッファの進捗仮想テキストを更新する。
-- write_lines が :write を使わなくなったため、旧実装が依存していた
-- BufWritePost 経由の自動更新が効かなくなった分をここで肩代わりする。
local function refresh_project_views_if_relevant(path)
	local filename = vim.fn.fnamemodify(path, ":t")
	if filename ~= "inbox.md" and filename ~= "todo.md" then
		return
	end
	pcall(function()
		local ui_project = require("gtodo-md.ui.project")
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(b) then
				ui_project.render_project_tasks(b)
			end
		end
	end)
end

-- 行リストをファイルへアトミックに書き込む(改行コードを指定)
local function write_lines_to_disk(path, lines, use_crlf)
	local tmp_path = path .. ".tmp"
	local f = io.open(tmp_path, "wb")
	if f then
		local nl = use_crlf and "\r\n" or "\n"
		for _, line in ipairs(lines) do
			f:write(line .. nl)
		end
		f:close()
		vim.fn.rename(tmp_path, path)
	end
end

-- ファイルまたはバッファに行リストを書き込む。
--
-- バッファが開いている場合でも nvim_buf_call + :write は使わない。
-- カレントバッファを一瞬切り替えることによる画面のちらつき(#57)や、
-- BufWritePre 等の意図しないautocmd発火(検証の誤発火・処理の多重発火)を
-- 避けるため、バッファへは直接内容を反映して modified フラグをクリアするに
-- 留め、ディスクへは別途アトミックに書き込む。
--
-- バッファが未保存(dirty)であっても常に反映・保存する。read_lines が
-- ライブバッファの内容(未保存分を含む)を読み取った上でこの関数に渡される
-- 想定のため、自動処理による変更とユーザーの未保存編集はマージされて
-- 保存され、未保存編集が失われることはない。
function M.write_lines(path, lines)
	local buf = get_buf_by_name(path)

	if buf then
		update_lines_incrementally(buf, lines)
		if vim.bo[buf].modified then
			vim.bo[buf].modified = false
		end
		write_lines_to_disk(path, lines, vim.bo[buf].fileformat == "dos")

		-- :write を使わずディスクへ直接書き込んだため、Vimが内部で持つ
		-- 「最後に確認したファイルの更新時刻」がこの書き込みを認識しないまま
		-- 古い値で残ってしまう。これを放置すると、後で別の編集が加わった際に
		-- Vimが(実際にはこのプラグイン自身が書いた)今回の変更を「外部での
		-- 変更」と誤認し、W12/W13警告を誤って出してしまう。バッファは既に
		-- クリーンな状態のため、この checktime は内容の再読み込みを伴わず
		-- サイレントに完了する(バッファ番号を明示指定するためカレントバッファの
		-- 切り替えも発生しない)。
		pcall(vim.cmd, "silent! checktime " .. buf)
	else
		local is_crlf = false
		if vim.fn.filereadable(path) == 1 then
			local fr = io.open(path, "rb")
			if fr then
				local content = fr:read(2048) or ""
				if content:find("\r\n") then
					is_crlf = true
				end
				fr:close()
			end
		end

		write_lines_to_disk(path, lines, is_crlf)
	end

	refresh_project_views_if_relevant(path)
end

-- 指定ファイルをパースして、セクションごとの行のリストにする
function M.read_todo_file(filepath)
	local lines = M.read_lines(filepath)
	if #lines == 0 then
		return { sections = {}, section_order = {}, header = {} }
	end
	return M.parse_markdown(lines)
end

-- #94: 見出しが config.section_aliases(key) に含まれる名前(デフォルト名/
-- 前回の設定名)であれば、その場で現在のカスタム名へ正規化する。これにより
-- due.lua等の既存の config.sections.* 参照箇所は一切変更せずに動作し続け、
-- 既存ファイルの見出しをユーザーに手動でリネームさせる必要もない
-- (次回保存時に write_todo_file が新しい名前で書き戻す)。
local function normalize_section_name(name)
	for key, _ in pairs(config.default_sections) do
		for _, alias in ipairs(config.section_aliases(key)) do
			if name == alias then
				return config.sections[key]
			end
		end
	end
	return name
end

function M.parse_markdown(lines)
	local data = {
		header = {},
		sections = {},
		section_order = {},
	}

	local current_section = "default"
	data.sections[current_section] = {}

	local header_done = false

	for _, line in ipairs(lines) do
		-- ## セクション境界
		local sec_name = line:match("^##%s+(.*)$")
		local task = task_mod.parse(line)

		if sec_name then
			sec_name = normalize_section_name(vim.trim(sec_name))
			current_section = sec_name
			if not data.sections[current_section] then
				data.sections[current_section] = {}
				table.insert(data.section_order, current_section)
			end
			header_done = true
		elseif task then
			header_done = true
		end

		if not header_done then
			table.insert(data.header, line)
		elseif not sec_name then
			local target_items = data.sections[current_section]

			if task then
				table.insert(target_items, { type = "task", task = task, line = line })
			else
				-- 空行はソート時のインデックスズレやMarkdownリスト分断の原因になるため無視する
				-- ### 見出し等の非タスク行はそのまま type="text" として保持し、
				-- 元の位置に書き戻す（sort.lua が並び替えの境界として扱う）。
				if vim.trim(line) ~= "" then
					table.insert(target_items, { type = "text", line = line })
				end
			end
		end
	end

	return data
end

-- items リスト（task/text のフラット配列）を行リストに変換するローカルヘルパー
-- seen_ids: この write_todo_file 呼び出し全体(全セクション・全サブセクション)で
-- 使用済みのIDを追跡する共有テーブル。コピー&ペーストで複製されたタスクが
-- 同じIDを持ち続けないよう、既に登場済みのIDを持つタスクは再発行させる
-- (ファイル内で最初に登場した方が元のIDを保持する)。
local function items_to_lines(items, lines, seen_ids)
	for _, item in ipairs(items) do
		if item.type == "task" then
			if item.task.id and item.task.id ~= "" and seen_ids[item.task.id] then
				item.task.id = nil -- 重複しているので serialize に再発行させる
			end
			local line = task_mod.serialize(item.task)
			seen_ids[item.task.id] = true
			table.insert(lines, line)
		else
			local text = item.line
			if vim.trim(text) == "" then
				if #lines > 0 and vim.trim(lines[#lines]) ~= "" then
					table.insert(lines, text)
				end
			else
				-- 見出し行(### 等)は前後に空行を入れる。markdownlint 等の
				-- 一般的な整形規約(見出しは空行で囲む)に沿わせるための処理で、
				-- サブセクションを構造化データとして特別扱いしているわけではない
				-- (## セクション見出し自体は data.header 側で別途処理される)。
				local is_heading = text:match("^#+%s") ~= nil
				if is_heading and #lines > 0 and lines[#lines] ~= "" then
					table.insert(lines, "")
				end
				table.insert(lines, text)
				if is_heading then
					table.insert(lines, "")
				end
			end
		end
	end
end

-- パースしたデータを書き戻す
function M.write_todo_file(filepath, data)
	local lines = {}
	-- このファイル書き出し全体を通してIDの重複を検知するための共有テーブル
	local seen_ids = {}

	for _, l in ipairs(data.header) do
		table.insert(lines, l)
	end

	-- default セクション（## なし領域）の書き出し
	local default_items = data.sections["default"] or {}
	if #default_items > 0 then
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		items_to_lines(default_items, lines, seen_ids)
	end

	for _, sec in ipairs(data.section_order) do
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		table.insert(lines, "## " .. sec)
		table.insert(lines, "")

		items_to_lines(data.sections[sec] or {}, lines, seen_ids)
	end

	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	table.insert(lines, "")

	M.write_lines(filepath, lines)
	return true
end

function M.ensure_files()
	local data_dir = config.get("data_dir")
	local files = {
		{ path = data_dir .. "/inbox.md", title = "# Inbox\n" },
		{
			path = data_dir .. "/todo.md",
			title = string.format(
				"# Todo\n\n## %s\n\n## %s\n\n## %s\n\n## %s",
				config.sections.TODAY,
				config.sections.NEXT,
				config.sections.WAITING,
				config.sections.SOMEDAY
			),
		},
		{ path = data_dir .. "/done.md", title = "# Done\n" },
		{ path = data_dir .. "/cancelled.md", title = "# Cancelled\n" },
	}

	for _, f in ipairs(files) do
		if vim.fn.filereadable(f.path) == 0 then
			local file = io.open(f.path, "wb")
			if file then
				file:write(f.title .. "\n")
				file:close()
			end
		end
	end
end

return M
