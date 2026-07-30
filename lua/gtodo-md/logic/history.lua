local M = {}
local task_mod = require("gtodo-md.task")
local io_mod = require("gtodo-md.io")

-- バッファが未保存の場合はサイレントに保存する
-- append_to_history は read_lines() でバッファ優先読みをするため、
-- 読み込み前にバッファをディスクと同期しておく必要がある。
local function flush_buf_if_modified(filepath)
	local realpath = vim.fn.fnamemodify(filepath, ":p")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local bufname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
			if bufname == realpath and vim.bo[buf].modified then
				pcall(vim.api.nvim_buf_call, buf, function()
					vim.cmd("silent! write")
				end)
				break
			end
		end
	end
end

-- 履歴ファイル (done.md / cancelled.md) へタスクを追記する
function M.append_to_history(filepath, header_title, section_name, tasks)
	-- バッファ未保存状態をディスクへ先に同期する（read_lines がバッファ優先のため）
	flush_buf_if_modified(filepath)

	local lines = io_mod.read_lines(filepath)

	-- ファイルが存在しない（空リスト）場合はヘッダーを生成する
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
