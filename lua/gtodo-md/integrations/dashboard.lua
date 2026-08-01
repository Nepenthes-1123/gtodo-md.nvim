local M = {}
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

-- 様々なダッシュボード(自作スクリプト等)で汎用的に使える
-- タスクのテキストとハイライト情報のリストを返す
function M.get_tasks_lines(limit)
	limit = limit or 5
	local data_dir = config.get("data_dir")
	if not data_dir then
		return {}
	end

	local todo_path = data_dir .. "/todo.md"
	if vim.fn.filereadable(todo_path) == 0 then
		return {}
	end

	local data = io_mod.read_todo_file(todo_path)
	local today_tasks = {}

	if data.sections[config.sections.TODAY] then
		for _, item in ipairs(data.sections[config.sections.TODAY]) do
			if item.type == "task" and item.task.status == " " then
				table.insert(today_tasks, item.task)
				if #today_tasks >= limit then
					break
				end
			end
		end
	end

	local result = {}
	if #today_tasks == 0 then
		table.insert(result, { text = "  ✨ すべてのタスクが完了しています", hl = "Comment" })
	else
		for _, task in ipairs(today_tasks) do
			local content = task.content
			local icon = "  [ ] "

			-- 優先度によるハイライトの切り替え
			local p_match = content:match("^%(([A-Z])%)")
			local hl = "Special"
			if p_match == "A" then
				hl = "DiagnosticError"
			elseif p_match == "B" then
				hl = "DiagnosticWarn"
			elseif p_match == "C" then
				hl = "DiagnosticInfo"
			end

			table.insert(result, { icon = icon, text = content, hl = hl })
		end
	end

	return result
end

-- Snacks Dashboard (snacks.nvim) 用のウィジェットセクション
function M.snacks_section()
	local lines = M.get_tasks_lines(5)

	-- Snacks.dashboard.Item の配列としてセクションを構築
	local items = {}

	-- 見出し
	table.insert(items, {
		text = { { "📝 Today's Tasks", hl = "Title" } },
		padding = 1,
		-- 最初の行にアクションとキーマップを付ける
		action = function()
			vim.cmd("lua require('gtodo-md.ui').open_todo_float()")
		end,
		key = "t",
	})

	if #lines == 0 then
		table.insert(items, { text = { { "  ✨ すべてのタスクが完了しています", hl = "Comment" } } })
	else
		for _, line in ipairs(lines) do
			local text_parts = {}
			if line.icon then
				table.insert(text_parts, { line.icon, hl = "Comment" })
			end
			table.insert(text_parts, { line.text, hl = line.hl })

			table.insert(items, {
				text = text_parts,
				-- actionを設定することでダッシュボード上で選択・フォーカス可能になる
				action = function()
					vim.cmd("lua require('gtodo-md.ui').open_todo_float()")
				end,
			})
		end
	end

	return items
end

-- Alpha (alpha-nvim) 用のウィジェットセクション
function M.alpha_section()
	local lines = M.get_tasks_lines(5)
	local alpha_lines = { "📅 Today's Tasks", "" }
	for _, line in ipairs(lines) do
		if line.icon then
			table.insert(alpha_lines, line.icon .. line.text)
		else
			table.insert(alpha_lines, line.text)
		end
	end

	return {
		type = "text",
		val = alpha_lines,
		opts = {
			hl = "Type",
			position = "center",
		},
	}
end

return M
