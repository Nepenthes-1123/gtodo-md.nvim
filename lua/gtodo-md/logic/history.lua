local M = {}
local task_mod = require("gtodo-md.task")
local io_mod = require("gtodo-md.io")

-- 履歴ファイル (done.md / cancelled.md) へタスクを追記する
-- バッファが開いている場合は io_mod.read_lines がその内容(未保存分を含む)を
-- 優先して返すため、ディスク直読みによる未保存編集の見落とし・上書きを避けられる
function M.append_to_history(filepath, header_title, section_name, tasks)
	local lines = io_mod.read_lines(filepath)

	if #lines == 0 then
		table.insert(lines, "# " .. header_title)
		table.insert(lines, "")
	end

	-- 対象セクションが「存在するか」だけでなく「どこにあるか」を見る。
	-- 振り分けは completed_at の月で行うため、対象が必ずしも最後のセクションとは限らない
	-- (月をまたいで放置された完了タスクは過去月の見出しへ入る)。位置を見ずに末尾へ
	-- 足すと、実際の完了月とは違う見出しの配下に無警告で紛れ込む。
	local header = "## " .. section_name
	local section_start
	for i, line in ipairs(lines) do
		if line == header then
			section_start = i
			break
		end
	end

	-- 既定はファイル末尾。対象セクションが最後なら従来どおりここへ追記される。
	local insert_at = #lines + 1

	if section_start then
		for i = section_start + 1, #lines do
			if lines[i]:match("^## ") then
				-- 後ろに別のセクションがある。その直前(= 対象セクションの末尾)へ入れる。
				-- 見出し間の区切りの空行より前に置きたいので、空行の分だけ遡る。
				insert_at = i
				while insert_at - 1 > section_start and vim.trim(lines[insert_at - 1]) == "" do
					insert_at = insert_at - 1
				end
				break
			end
		end
	else
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		table.insert(lines, header)
		table.insert(lines, "")
		insert_at = #lines + 1
	end

	for offset, t in ipairs(tasks) do
		table.insert(lines, insert_at + offset - 1, task_mod.serialize(t))
	end

	io_mod.write_lines(filepath, lines)
end

return M
