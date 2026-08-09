-- 保存時バリデーションの純粋なルール群。
-- init.lua の BufWritePre コールバックから呼ばれるが、このモジュール自体は
-- vim.api やバッファ・ファイルパスに一切触れない（引数はプレーンな値のみ）。
-- 対象バッファが data_dir 配下かどうかの判定(#91)は呼び出し元の責務。
local M = {}

local config = require("gtodo-md.config")

-- 必須セクションのキー集合。config.default_sections(セクション名の正本)から
-- 導出する(#96参考: 独自の重複リストを持たない)。pairs() の走査順は
-- 実装依存で不定なため、missing_todo_sections が返すリストの順序を
-- 安定させるために sort しておく。
local SECTION_KEYS = {}
for key, _ in pairs(config.default_sections) do
	table.insert(SECTION_KEYS, key)
end
table.sort(SECTION_KEYS)

-- 履歴ファイル(done.md/cancelled.md)の年月セクション見出しの正本
local HISTORY_SECTION_PATTERN = "^##%s+(%d%d%d%d%-%d%d)$"

-- フロントマターの終端 `---` の行番号を返す。1行目が `---` でない、または
-- 終端が見つからない場合は nil。
local function frontmatter_end_index(lines)
	if #lines == 0 or lines[1] ~= "---" then
		return nil
	end
	for i = 2, #lines do
		if lines[i] == "---" then
			return i
		end
	end
	return nil
end

-- todo.md に不足している必須セクション見出しのリストを返す。
-- #94: config.sections.* はsetup()でカスタム名に変更できるが、
-- デフォルト名(Today等)も常にエイリアスとして受理する(既存ファイルの
-- 見出しをユーザーに手動でリネームさせないため)。config.section_aliases
-- がキーごとの有効な名称候補(カスタム名+デフォルト名)を返す。
function M.missing_todo_sections(lines)
	local found = {}
	for _, key in ipairs(SECTION_KEYS) do
		found[key] = false
	end

	for _, line in ipairs(lines) do
		local sec = line:match("^##%s+(.*)$")
		if sec then
			sec = vim.trim(sec)
			for _, key in ipairs(SECTION_KEYS) do
				for _, alias in ipairs(config.section_aliases(key)) do
					if sec == alias then
						found[key] = true
					end
				end
			end
		end
	end

	local missing = {}
	for _, key in ipairs(SECTION_KEYS) do
		if not found[key] then
			table.insert(missing, "## " .. config.sections[key])
		end
	end
	return missing
end

-- 必須のトップヘッダー(`# Inbox` 等)が残っているかどうかを返す
function M.has_required_header(lines, expected_header)
	for _, line in ipairs(lines) do
		if line:match("^" .. expected_header) then
			return true
		end
	end
	return false
end

-- `## YYYY-MM` 見出しの集合を `{ ["YYYY-MM"] = true }` として返す
function M.collect_history_sections(lines)
	local secs = {}
	for _, line in ipairs(lines) do
		local sec = line:match(HISTORY_SECTION_PATTERN)
		if sec then
			secs[sec] = true
		end
	end
	return secs
end

-- original_secs (読み込み時に存在していた年月セクション) のうち、
-- lines から失われているものの見出し文字列のリストを返す
function M.missing_history_sections(lines, original_secs)
	local found_secs = M.collect_history_sections(lines)

	local missing_secs = {}
	for sec, _ in pairs(original_secs or {}) do
		if not found_secs[sec] then
			table.insert(missing_secs, "## " .. sec)
		end
	end
	return missing_secs
end

-- フロントマターの `created:` の値を返す。存在しなければ nil
function M.extract_frontmatter_created(lines)
	local end_idx = frontmatter_end_index(lines)
	if not end_idx then
		return nil
	end

	for i = 2, end_idx - 1 do
		local created_val = lines[i]:match("^created:%s*(.*)$")
		if created_val then
			return vim.trim(created_val)
		end
	end
	return nil
end

-- projects/*.md のフロントマターを検証し、エラー文字列のリストを返す。
-- 空リストなら妥当。original_created は読み込み時の created の値(nil可)で、
-- 一度設定されたら変更不可という不変条件の照合に使う。
function M.validate_project_frontmatter(lines, proj_name, original_created)
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

	local end_idx = frontmatter_end_index(lines)
	if end_idx then
		for i = 2, end_idx - 1 do
			local key, val = lines[i]:match("^(%w+):%s*(.*)$")
			if key then
				if required_keys[key] ~= nil then
					required_keys[key] = true
				end
				val = vim.trim(val or "")
				if key == "tag" and val == proj_name then
					tag_matches_filename = true
				elseif key == "created" then
					if original_created and val ~= original_created then
						created_changed = true
					end
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

	if end_idx and #missing_keys == 0 and tag_matches_filename and not created_changed then
		valid_frontmatter = true
	end

	local errors = {}
	if valid_frontmatter then
		return errors
	end

	if created_changed then
		table.insert(errors, "created (作成日) の変更は禁止されています")
	end
	if not tag_matches_filename then
		table.insert(errors, string.format("tag の値がファイル名 (%s) と一致していません", proj_name))
	end

	if #missing_keys > 0 then
		table.insert(errors, "必須項目が不足しています (" .. table.concat(missing_keys, ", ") .. ")")
	end

	if #errors == 0 then
		table.insert(errors, "フロントマターのフォーマット (---) が破損しています")
	end

	return errors
end

return M
