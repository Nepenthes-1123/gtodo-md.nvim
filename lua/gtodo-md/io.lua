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

-- data.sections[sec] の items を返すヘルパー（フラット互換のための内部ユーティリティ）
-- 現在の実装では sections[sec] は常にネスト構造なので、そのまま .items を返す
function M.get_section_items(sec_data)
	if type(sec_data) == "table" and sec_data.items ~= nil then
		return sec_data.items
	end
	-- 旧フラット構造への互換（本来到達しないが安全ガード）
	return sec_data or {}
end

-- 空のセクションデータを生成するヘルパー
local function new_section()
	return { items = {}, subsections = {} }
end

function M.parse_markdown(lines)
	local data = {
		header = {},
		sections = {},
		section_order = {},
	}

	local current_section = "default"
	data.sections[current_section] = new_section()

	-- 現在のサブセクション状態
	-- nil のときはトップレベル（### なし）、文字列のときはそのサブセクション配下
	local current_subsection = nil

	local header_done = false

	for _, line in ipairs(lines) do
		-- ## セクション境界
		local sec_name = line:match("^##%s+(.*)$")
		-- ### サブセクション境界（## に続く # で始まるものは除外済みなので ^### で OK）
		local subsec_name = (not sec_name) and line:match("^###%s+(.-)%s*$") or nil
		local task = task_mod.parse(line)

		if sec_name then
			sec_name = vim.trim(sec_name)
			current_section = sec_name
			current_subsection = nil -- 新セクションでサブセクションをリセット
			if not data.sections[current_section] then
				data.sections[current_section] = new_section()
				table.insert(data.section_order, current_section)
			end
			header_done = true
		elseif subsec_name then
			-- ### 見出し: 現在のセクション配下に新しいサブセクションを追加
			current_subsection = subsec_name
			local sec = data.sections[current_section]
			-- 同名サブセクションが既に存在する場合は再利用しない（順序保持のため新規追加）
			table.insert(sec.subsections, { name = subsec_name, items = {} })
			header_done = true
		elseif task then
			header_done = true
		end

		if not header_done then
			table.insert(data.header, line)
		elseif not sec_name and not subsec_name then
			local sec = data.sections[current_section]
			-- 挿入先: サブセクション配下 or トップレベル items
			local target_items
			if current_subsection then
				-- 末尾のサブセクション（最後に追加されたもの）に挿入
				local sub = sec.subsections[#sec.subsections]
				target_items = sub and sub.items or sec.items
			else
				target_items = sec.items
			end

			if task then
				table.insert(target_items, { type = "task", task = task, line = line })
			else
				-- 空行はソート時のインデックスズレやMarkdownリスト分断の原因になるため無視する
				if vim.trim(line) ~= "" then
					table.insert(target_items, { type = "text", line = line })
				end
			end
		end
	end

	return data
end

-- items リスト（task/text のフラット配列）を行リストに変換するローカルヘルパー
local function items_to_lines(items, lines)
	for _, item in ipairs(items) do
		if item.type == "task" then
			table.insert(lines, task_mod.serialize(item.task))
		else
			local text = item.line
			if vim.trim(text) == "" then
				if #lines > 0 and vim.trim(lines[#lines]) ~= "" then
					table.insert(lines, text)
				end
			else
				table.insert(lines, text)
			end
		end
	end
end

-- パースしたデータを書き戻す
function M.write_todo_file(filepath, data)
	local lines = {}

	for _, l in ipairs(data.header) do
		table.insert(lines, l)
	end

	-- default セクション（## なし領域）の書き出し
	local default_sec = data.sections["default"]
	local default_items = default_sec and M.get_section_items(default_sec) or {}
	if #default_items > 0 then
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		items_to_lines(default_items, lines)
	end

	for _, sec in ipairs(data.section_order) do
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		table.insert(lines, "## " .. sec)
		table.insert(lines, "")

		local sec_data = data.sections[sec] or new_section()

		-- トップレベル items の書き出し
		items_to_lines(M.get_section_items(sec_data), lines)

		-- サブセクションの書き出し
		local subsections = (type(sec_data) == "table" and sec_data.subsections) or {}
		for _, sub in ipairs(subsections) do
			-- サブセクション見出しの前に空行を入れる（直前が空でなければ）
			if #lines > 0 and lines[#lines] ~= "" then
				table.insert(lines, "")
			end
			table.insert(lines, "### " .. sub.name)
			table.insert(lines, "")
			items_to_lines(sub.items, lines)
		end
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
