-- #86/#90 根本原因の回帰テスト。
-- Todayダッシュボードウィジェットは get_section_items 経由でトップレベルの
-- items しか見ておらず、### 見出し配下の未完了タスクは一覧に出てこなかった。

local dashboard_mod = require("gtodo-md.integrations.dashboard")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("dashboard.get_tasks_lines", function()
	local data_dir, todo_path

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
		todo_path = data_dir .. "/todo.md"
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	it("### 見出し配下のTodayタスクも一覧に含まれる", function()
		io_mod.write_lines(todo_path, {
			"# Todo",
			"",
			"## Today",
			"",
			"### 仕事",
			"- [ ] 仕事タスクA",
			"",
		})

		local result = dashboard_mod.get_tasks_lines(5)

		local found = false
		for _, entry in ipairs(result) do
			if entry.text and entry.text:find("仕事タスクA", 1, true) then
				found = true
			end
		end
		assert.is_true(
			found,
			"### 見出し配下のタスクが一覧に含まれていない: " .. vim.inspect(result)
		)
	end)
end)
