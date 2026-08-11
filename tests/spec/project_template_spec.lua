-- #97 回帰テスト: create_project_file が生成するテンプレートの title/due/
-- status/members フィールドに不要な末尾スペースが含まれていた。
-- フォーマッタとの相性問題や可読性低下の原因になっていた。

local project_mod = require("gtodo-md.ui.project")
local config = require("gtodo-md.config")

describe("ui.project.create_project_file テンプレート (#97)", function()
	local data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	it("生成されるテンプレートのどの行にも末尾の空白が含まれない", function()
		project_mod.create_project_file("my_project")

		local lines = vim.fn.readfile(data_dir .. "/projects/my_project.md")
		for i, line in ipairs(lines) do
			assert.are.same(
				line,
				(line:gsub("%s+$", "")),
				"行 " .. i .. " に末尾の空白が残っている: " .. vim.inspect(line)
			)
		end
	end)
end)
