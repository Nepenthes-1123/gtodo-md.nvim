local M = {}
local task_mod = require("gtodo-md.task")

-- active_splits[source_buf] は現在アクティブな split ポップアップの配列。
-- 各エントリは { id = task.id(あれば) } または { row, extmark_id(発行後) } の
-- いずれかの形を取る(#92)。タスク行(チェックボックス行としてparseできる)は
-- 一意なタスクidをロックキーに使うため、行の挿入・削除で行番号がズレても
-- 対象を見失わない。idを持たない行(チェックボックスでない素のリスト項目)は
-- 従来通り行番号で識別するが、extmark発行後はextmarkの現在位置を正として
-- 解決する。
local active_splits = {}
local ns_id = vim.api.nvim_create_namespace("gtodo_split_ns")
local AUGROUP = vim.api.nvim_create_augroup("GtodoMdSplit", { clear = true })

-- row(1-indexed)・line から、既にアクティブな split がこの行を指しているかを
-- 判定する。id持ちエントリはid一致で、それ以外は現在位置(extmarkがあれば
-- そこから解決した行番号、無ければプロンプト表示中の元の行番号)で判定する。
local function find_active_entry(source_buf, row, line)
	local entries = active_splits[source_buf]
	if not entries then
		return nil
	end
	local task = task_mod.parse(line)
	for _, entry in ipairs(entries) do
		if entry.id then
			if task and task.id == entry.id then
				return entry
			end
		else
			local current_row = entry.row
			if entry.extmark_id then
				local mark = vim.api.nvim_buf_get_extmark_by_id(source_buf, ns_id, entry.extmark_id, {})
				if mark and #mark > 0 then
					current_row = mark[1] + 1
				end
			end
			if current_row == row then
				return entry
			end
		end
	end
	return nil
end

local function release_entry(source_buf, entry)
	local entries = active_splits[source_buf]
	if not entries then
		return
	end
	for i, e in ipairs(entries) do
		if e == entry then
			table.remove(entries, i)
			return
		end
	end
end

local function get_list_marker_info(line)
	local bq_prefix = line:match("^(%s*>[>%s]*)") or ""
	local stripped = line:sub(#bq_prefix + 1)

	local u_match = stripped:match("^(%s*[%-%*+]%s+)")
	if u_match then
		return bq_prefix, u_match, vim.fn.strdisplaywidth(u_match)
	end

	local o_match = stripped:match("^(%s*%d+[%.%)]%s+)")
	if o_match then
		return bq_prefix, o_match, vim.fn.strdisplaywidth(o_match)
	end

	return bq_prefix, nil, nil
end

local function get_visual_indent(str)
	local leading = str:match("^(%s*)")
	if not leading then
		return 0
	end
	local spaces = leading:gsub("\t", string.rep(" ", vim.bo.shiftwidth or 4))
	return #spaces
end

local function escape_lua_pattern(s)
	return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- 入力されたプロジェクトタグを、ファイル名として安全な形へ正規化する。
-- 引数は trim 済みの文字列を想定する。正規化の結果が空文字になる場合(記号のみの
-- 入力など)は空文字を返し、その扱い(処理の中断)は呼び出し元に委ねる。
local function sanitize_project_tag(tag)
	local result = tag:gsub("^%.+", ""):gsub("%.+$", "")
	result = result:gsub('[<>:"/\\|?*]', "-")
	result = result:gsub("%s+", "-")
	result = result:gsub("%-+", "-")
	result = result:gsub("^%-+", ""):gsub("%-+$", "")

	local base = result:match("^([^.]+)")
	if base then
		local dos_reserved = {
			CON = true,
			PRN = true,
			AUX = true,
			NUL = true,
			COM1 = true,
			COM2 = true,
			COM3 = true,
			COM4 = true,
			LPT1 = true,
			LPT2 = true,
			LPT3 = true,
		}
		if dos_reserved[base:upper()] then
			result = result:gsub("^([^.]+)", "%1_proj")
		end
	end

	return vim.fn.strcharpart(result, 0, 80)
end

-- 親タスク行の `+project` タグを書き換える。existing_tag は行から抽出済みの
-- 既存タグ(無ければ nil)、new_tag は正規化済みの新しいタグ(空文字なら除去)。
local function rewrite_project_tag(line, existing_tag, new_tag)
	if existing_tag and new_tag == "" then
		return (line:gsub("%s*%+" .. escape_lua_pattern(existing_tag) .. "%s*$", ""))
	elseif existing_tag and new_tag ~= "" and existing_tag ~= new_tag then
		return (line:gsub("%+" .. escape_lua_pattern(existing_tag) .. "(%s*)$", "+" .. new_tag .. "%1"))
	elseif not existing_tag and new_tag ~= "" then
		return line:gsub("%s*$", "") .. " +" .. new_tag
	end
	return line
end

-- フロートウィンドウのタイトル用に、親タスク行から本文だけを取り出して要約する。
local function summarize_parent_text(line)
	local text = line

	-- マーカー部分を除去
	local t_bq, t_marker, _ = get_list_marker_info(text)
	if t_marker then
		text = text:sub(#t_bq + #t_marker + 1)
	end

	-- チェックボックスを除去（[ ] や [x] など）
	text = text:gsub("^%s*%[.%]%s+", "")

	-- メタデータ (+, @, #) を除去
	text = text:gsub("[%+@#][%w%-_/%.%(%):]+", "")

	-- key:value 形式のメタデータ (例: due:2023) も除去（ただし URL の http(s) は残す）
	text = text:gsub("%s*[%w%-_]+:[%w%-_/%.%(%):]+", function(match)
		if match:match("^%s*https?:") then
			return match
		else
			return ""
		end
	end)
	text = vim.trim(text)

	if vim.fn.strchars(text) > 40 then
		text = vim.fn.strcharpart(text, 0, 40) .. "..."
	end

	return text
end

-- テスト用に公開する純関数
M._sanitize_project_tag = sanitize_project_tag
M._rewrite_project_tag = rewrite_project_tag
M._summarize_parent_text = summarize_parent_text

local function create_project_file_if_missing(tag)
	require("gtodo-md.utils").create_project_file(tag)
end

-- カーソル行が分割の対象になり得るかを判定する。対象外なら(必要に応じて通知した上で)
-- nil を返す。返り値: row(1-indexed), parent_line, bq_prefix
local function resolve_split_target(source_buf)
	if not vim.bo[source_buf].modifiable then
		vim.notify("[gtodo-md] Buffer is not modifiable.", vim.log.levels.WARN)
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local parent_line = vim.api.nvim_buf_get_lines(source_buf, row - 1, row, false)[1]

	if not parent_line then
		return nil
	end

	local bq_prefix, marker, _ = get_list_marker_info(parent_line)
	if not marker then
		vim.notify("[gtodo-md] Not on a valid task line.", vim.log.levels.WARN)
		return nil
	end

	if find_active_entry(source_buf, row, parent_line) then
		vim.notify("[gtodo-md] A split window is already active for this task.", vim.log.levels.WARN)
		return nil
	end

	return row, parent_line, bq_prefix
end

-- #92: タスク行ならidをロックキーにする。id未発行(保存サイクルを経ていない
-- 手打ちタスク等)ならここで発行して行末へ埋め込む(id:はconcealされるため
-- 見た目には影響しない)。他のタグ位置やフォーマットを崩さないよう、
-- serializeで再構築せず末尾への追記に留める。
-- 返り値: entry, parent_line(idを発行した場合は付与後の行)
local function acquire_split_entry(source_buf, row, parent_line)
	local entry = { row = row }
	local task = task_mod.parse(parent_line)
	if task then
		if not task.id or task.id == "" then
			task.id = task_mod._generate_id()
			parent_line = vim.trim(parent_line) .. " id:" .. task.id
			vim.api.nvim_buf_set_lines(source_buf, row - 1, row, false, { parent_line })
		end
		entry.id = task.id
	end

	active_splits[source_buf] = active_splits[source_buf] or {}
	table.insert(active_splits[source_buf], entry)

	return entry, parent_line
end

-- commit時の親行追跡用と、#92のロック解決用の2つのextmarkを設置する。
-- 返り値: parent_extmark_id(right_gravity=false), lock_extmark_id(right_gravity=true)
local function create_tracking_extmarks(source_buf, row)
	local parent_extmark_id = vim.api.nvim_buf_set_extmark(source_buf, ns_id, row - 1, 0, {
		right_gravity = false,
	})

	-- #92のロック解決専用のextmark。上のparent_extmark_idはright_gravity=falseで
	-- commit時の親行追跡用に既存の挙動のまま残すが、これは「同じ行位置に
	-- 挿入されたテキストの前に留まる」性質があり、行そのものの挿入(他の
	-- 場所での編集で上に新しい行が入る場合)には追従しない。ロック解決には
	-- 「上に行が挿入されたら自分も下にズレる」動きが必要なため、
	-- right_gravity=true の別のextmarkを用意する。
	local lock_extmark_id = vim.api.nvim_buf_set_extmark(source_buf, ns_id, row - 1, 0, {
		right_gravity = true,
	})

	return parent_extmark_id, lock_extmark_id
end

-- 分割内容を入力するスクラッチバッファとフロートウィンドウを構築する。
-- 返り値: scratch_buf, scratch_win
local function open_split_window(parent_line)
	local scratch_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[scratch_buf].bufhidden = "wipe"
	vim.bo[scratch_buf].filetype = "markdown"

	vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "- [ ] " })

	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.6)

	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
		title = " Splitting: " .. summarize_parent_text(parent_line) .. " ",
		title_pos = "center",
	}

	if vim.fn.has("nvim-0.10") == 1 then
		win_opts.footer = " [Commit: g<CR> or <Leader><CR>] | [Cancel: :q] "
		win_opts.footer_pos = "center"
	else
		win_opts.title = win_opts.title .. " | [Commit: g<CR>] "
	end

	local scratch_win = vim.api.nvim_open_win(scratch_buf, true, win_opts)

	return scratch_buf, scratch_win
end

-- #92: ロック解放を BufWipeout(バッファが :q 等で片付いた場合)だけに
-- 頼らず、WinClosed(ウィンドウが閉じられた場合)でも確実に行う。
-- 両方発火し得るため cleaned_up フラグで冪等にしている。
local function register_cleanup(split)
	local cleaned_up = false
	local function cleanup()
		if cleaned_up then
			return
		end
		cleaned_up = true
		if vim.api.nvim_buf_is_valid(split.source_buf) then
			pcall(vim.api.nvim_buf_del_extmark, split.source_buf, ns_id, split.parent_extmark_id)
			pcall(vim.api.nvim_buf_del_extmark, split.source_buf, ns_id, split.lock_extmark_id)
		end
		release_entry(split.source_buf, split.entry)
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = AUGROUP,
		buffer = split.scratch_buf,
		callback = cleanup,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = AUGROUP,
		pattern = tostring(split.scratch_win),
		callback = cleanup,
	})
end

-- commit時に親タスクの行番号を再解決する。extmarkの位置を起点に、行テキストが
-- 一致しなければ前後2行 → バッファ全体の順にフォールバックする。
-- extmarkそのものが失われていた場合のみ nil を返す。
-- 返り値: parent_row(0-indexed), current_parent_line
local function resolve_parent_row(source_buf, parent_extmark_id, parent_line)
	local mark = vim.api.nvim_buf_get_extmark_by_id(source_buf, ns_id, parent_extmark_id, {})
	if not mark or #mark == 0 then
		return nil
	end

	local parent_row = mark[1]
	local current_parent_line = vim.api.nvim_buf_get_lines(source_buf, parent_row, parent_row + 1, false)[1]

	if current_parent_line == parent_line then
		return parent_row, current_parent_line
	end

	-- Fallback: if extmark shifted (e.g. due to undo bugs), scan +/- 2 lines first
	for offset = -2, 2 do
		if offset ~= 0 then
			local check_row = parent_row + offset
			if check_row >= 0 then
				local check_line = vim.api.nvim_buf_get_lines(source_buf, check_row, check_row + 1, false)[1]
				if check_line == parent_line then
					return check_row, check_line
				end
			end
		end
	end

	-- Deep fallback: scan the ENTIRE buffer if still not found
	--
	-- #85: この行テキスト完全一致による探索は、同一テキストの行が複数存在すると
	-- Extmarkの旧位置に最も近いものを誤って選んでしまう可能性があった。
	-- task.lua の serialize が全タスクに一意な id: タグを付与するようになったため、
	-- 保存済みのタスク行は id: を含めて完全一致する限りIDも一致することになり、
	-- 「異なるタスクなのに行テキストが偶然衝突する」ケースは実質的に排除される。
	-- そのため、ここでの行テキスト一致自体をID比較に置き換える必要はない。
	-- 残るのは、IDがまだ付与されていない(保存サイクルを経ていない)タスク同士が
	-- 偶然同一テキストになるケースのみで、これは以前から変わらない既知の限界。
	local all_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
	local best_match_row = nil
	local min_dist = math.huge
	for i, line in ipairs(all_lines) do
		if line == parent_line then
			local dist = math.abs((i - 1) - parent_row)
			if dist < min_dist then
				min_dist = dist
				best_match_row = i - 1
			end
		end
	end
	if best_match_row then
		return best_match_row, all_lines[best_match_row + 1]
	end

	return parent_row, current_parent_line
end

local function extract_metadata(line)
	local metadata = {}
	for word in line:gmatch("[%+@#][%w%-_/%.%(%):]+") do
		table.insert(metadata, word)
	end
	for word in line:gmatch("[%w%-_]+:[%w%-_/%.%(%):]+") do
		if not word:match("^https?:") then
			table.insert(metadata, word)
		end
	end
	return metadata
end

local function get_meta_prefix(meta)
	return meta:match("^([%+@#][^%(%):]+)") or meta:match("^([^:]+:)") or meta
end

-- スクラッチバッファの内容(payload)を、ソースバッファへ差し込む行群へ変換する。
-- インデントを親行に合わせ、親タスクのメタデータを持たないサブタスクへ継承させる。
local function build_injection(source_buf, payload, bq_prefix, parent_line)
	local stripped_parent = parent_line:sub(#bq_prefix + 1)
	local parent_indent = get_visual_indent(stripped_parent)
	local base_offset = parent_indent -- フラットモデル：親と同じインデント

	local injection = {}
	local expandtab = vim.bo[source_buf].expandtab
	local sw = vim.bo[source_buf].shiftwidth
	if sw == 0 then
		sw = vim.bo[source_buf].tabstop
	end

	-- 親タスクからすべてのメタデータを抽出
	local parent_metadata = extract_metadata(parent_line)

	for _, p_line in ipairs(payload) do
		if p_line:match("^%s*$") then
			table.insert(injection, bq_prefix:gsub("%s+$", ""))
		else
			local p_indent_spaces = p_line:match("^(%s*)")
			p_indent_spaces = p_indent_spaces:gsub("\t", string.rep(" ", sw))
			local total_indent_num = base_offset + #p_indent_spaces
			local total_indent_str
			if not expandtab then
				local tabs = math.floor(total_indent_num / sw)
				local spaces = total_indent_num % sw
				total_indent_str = string.rep("\t", tabs) .. string.rep(" ", spaces)
			else
				total_indent_str = string.rep(" ", total_indent_num)
			end

			local text = p_line:match("^%s*(.*)$")
			local _, l_marker, _ = get_list_marker_info(text)

			if l_marker then
				local existing_metadata = extract_metadata(text)
				for _, meta in ipairs(parent_metadata) do
					local meta_prefix = get_meta_prefix(meta)
					local has_meta = false

					for _, e_meta in ipairs(existing_metadata) do
						if get_meta_prefix(e_meta) == meta_prefix then
							has_meta = true
							break
						end
					end

					if not has_meta then
						text = text:gsub("%s*$", "") .. " " .. meta
					end
				end
			end

			table.insert(injection, bq_prefix .. total_indent_str .. text)
		end
	end

	return injection
end

-- コミット処理を生成する。親行の位置ズレやテキスト変更を解決した上で、
-- 親タスクを分割後のタスク群で置き換える。
-- 親行が変更されユーザーが続行を選んだ場合は split.parent_line/bq_prefix を更新する。
local function make_commit(split)
	local is_committing = false

	return function()
		if is_committing then
			return
		end

		local source_buf = split.source_buf
		if
			not vim.api.nvim_buf_is_valid(source_buf)
			or not vim.api.nvim_buf_is_loaded(source_buf)
			or not vim.bo[source_buf].modifiable
		then
			vim.notify("[gtodo-md] Source buffer is invalid, unloaded, or unmodifiable.", vim.log.levels.ERROR)
			return
		end

		is_committing = true

		local parent_row, current_parent_line =
			resolve_parent_row(source_buf, split.parent_extmark_id, split.parent_line)
		if not parent_row then
			vim.notify("[gtodo-md] Parent task extmark was destroyed.", vim.log.levels.ERROR)
			is_committing = false
			return
		end

		if current_parent_line ~= split.parent_line then
			local c_bq_prefix, c_marker, _ = get_list_marker_info(current_parent_line)
			if not c_marker then
				vim.notify(
					string.format(
						"[gtodo-md] Parent task was modified and is no longer a valid task.\nExpected: '%s'\nFound: '%s'",
						split.parent_line,
						current_parent_line
					),
					vim.log.levels.ERROR
				)
				is_committing = false
				return
			end

			local choice = vim.fn.confirm("Parent task text changed. Inject here?", "&Yes\n&No")
			if choice ~= 1 then
				is_committing = false
				return
			end

			split.parent_line = current_parent_line
			split.bq_prefix = c_bq_prefix
		end

		local payload = vim.api.nvim_buf_get_lines(split.scratch_buf, 0, -1, false)
		if table.concat(payload, "\n"):match("^%s*$") then
			vim.notify("[gtodo-md] Empty payload. Aborting split.", vim.log.levels.INFO)
			vim.api.nvim_win_close(split.scratch_win, true)
			return
		end

		local injection = build_injection(source_buf, payload, split.bq_prefix, split.parent_line)

		pcall(function()
			vim.cmd("undojoin")
		end)
		-- 親タスクを削除し、分割されたタスク群に置き換える（フラットモデル）
		vim.api.nvim_buf_set_lines(source_buf, parent_row, parent_row + 1, false, injection)
		vim.api.nvim_win_close(split.scratch_win, true)
	end
end

local function setup_scratch_keymaps(scratch_buf, commit)
	vim.keymap.set("n", "g<CR>", commit, { buffer = scratch_buf, silent = true, desc = "Commit Split" })
	vim.keymap.set("n", "<Leader><CR>", commit, { buffer = scratch_buf, silent = true, desc = "Commit Split" })

	-- インサートモードでのエンターキーで自動的にチェックボックスを継続する
	vim.keymap.set("i", "<CR>", function()
		local line = vim.api.nvim_get_current_line()
		-- 現在の行が空のチェックボックスなら、それを消して通常の改行にする
		if line:match("^%s*%- %[%s*%]%s*$") then
			return "<C-u><CR>"
		-- チェックボックスがある行で改行したら、次の行にもチェックボックスを入れる
		elseif line:match("^%s*%- %[%s*%]") then
			return "<CR>- [ ] "
		else
			return "<CR>"
		end
	end, { buffer = scratch_buf, expr = true, remap = false })
end

function M.split_current_task()
	local source_buf = vim.api.nvim_get_current_buf()

	local row, parent_line, bq_prefix = resolve_split_target(source_buf)
	if not row then
		return
	end

	local entry
	entry, parent_line = acquire_split_entry(source_buf, row, parent_line)

	local existing_tag = parent_line:match("%+([%w%-_/%.]+)")

	vim.ui.input({ prompt = "Project tag (empty for plain split): ", default = existing_tag or "" }, function(input_tag)
		if input_tag == nil then
			release_entry(source_buf, entry)
			return
		end

		local new_tag = vim.trim(input_tag)

		if new_tag ~= "" then
			new_tag = sanitize_project_tag(new_tag)

			-- 正規化の結果が空になった場合(記号のみの入力など)は分割を中断する。
			-- 中断する以上ロックも手放すこと — 解放し忘れると find_active_entry が
			-- 以後ずっとこの残骸にヒットし、そのタスクの分割が Neovim 再起動まで
			-- 「A split window is already active」で恒久的にブロックされる。
			if new_tag == "" then
				release_entry(source_buf, entry)
				return
			end

			create_project_file_if_missing(new_tag)
		end

		local new_parent_line = rewrite_project_tag(parent_line, existing_tag, new_tag)

		if new_parent_line ~= parent_line then
			vim.api.nvim_buf_set_lines(source_buf, row - 1, row, false, { new_parent_line })
		end

		parent_line = vim.api.nvim_buf_get_lines(source_buf, row - 1, row, false)[1]

		local parent_extmark_id, lock_extmark_id = create_tracking_extmarks(source_buf, row)
		entry.extmark_id = lock_extmark_id

		local scratch_buf, scratch_win = open_split_window(parent_line)

		local split = {
			source_buf = source_buf,
			entry = entry,
			parent_line = parent_line,
			bq_prefix = bq_prefix,
			parent_extmark_id = parent_extmark_id,
			lock_extmark_id = lock_extmark_id,
			scratch_buf = scratch_buf,
			scratch_win = scratch_win,
		}

		register_cleanup(split)
		setup_scratch_keymaps(scratch_buf, make_commit(split))

		-- カーソルを最初の行の末尾に移動してインサートモードへ
		vim.api.nvim_win_set_cursor(scratch_win, { 1, 6 })
		vim.cmd("startinsert!")
	end)
end

return M
