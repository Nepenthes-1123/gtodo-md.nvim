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

	-- セクションがすでに存在するかチェック
	local has_section = false
	for _, line in ipairs(lines) do
		if line == "## " .. section_name then
			has_section = true
			break
		end
	end

	if not has_section then
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		table.insert(lines, "## " .. section_name)
		table.insert(lines, "")
	end

	for _, t in ipairs(tasks) do
		table.insert(lines, task_mod.serialize(t))
	end

	io_mod.write_lines(filepath, lines)
end

return M
