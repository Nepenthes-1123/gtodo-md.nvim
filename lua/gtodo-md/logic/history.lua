local M = {}
local task_mod = require("gtodo-md.task")
local io_mod = require("gtodo-md.io")

-- 履歴ファイル (done.md / cancelled.md) へタスクを追記する
function M.append_to_history(filepath, header_title, section_name, tasks)
	local lines = {}
	local file_exists = vim.fn.filereadable(filepath) == 1

	if file_exists then
		local f = io.open(filepath, "r")
		if f then
			for line in f:lines() do
				table.insert(lines, line)
			end
			f:close()
		end
	else
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
