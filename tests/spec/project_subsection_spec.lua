-- #86/#90 根本原因の回帰テスト。
-- render_project_tasks の parse_and_accumulate は get_section_items 経由で
-- トップレベルの items しか走査しておらず、### 見出し配下の +project タスクは
-- 進捗の virtual text に一切反映されなかった。

local project_mod = require("gtodo-md.ui.project")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("ui.project.render_project_tasks", function()
	local data_dir, proj_buf

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })

		io_mod.write_lines(data_dir .. "/inbox.md", { "# Inbox", "" })
		io_mod.write_lines(data_dir .. "/todo.md", {
			"# Todo",
			"",
			"## Today",
			"",
			"### 仕事",
			"- [ ] 仕事タスクP +myproj",
			"",
		})

		proj_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(proj_buf, data_dir .. "/projects/myproj.md")
		vim.api.nvim_buf_set_lines(proj_buf, 0, -1, false, {
			"---",
			"title: Test Project",
			"tag: myproj",
			"created: 2025-01-01",
			"status: active",
			"members: []",
			"---",
			"",
		})
	end)

	after_each(function()
		if proj_buf and vim.api.nvim_buf_is_valid(proj_buf) then
			vim.api.nvim_buf_delete(proj_buf, { force = true })
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it("### 見出し配下の +project タスクも進捗の virtual text に含まれる", function()
		project_mod.render_project_tasks(proj_buf)

		local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")
		local marks = vim.api.nvim_buf_get_extmarks(proj_buf, ns_id, 0, -1, { details = true })
		assert.equals(1, #marks, "進捗表示のextmarkが1件のはず: " .. vim.inspect(marks))

		local virt_lines = marks[1][4].virt_lines
		local found = false
		for _, vline in ipairs(virt_lines) do
			for _, chunk in ipairs(vline) do
				if chunk[1]:find("仕事タスクP", 1, true) then
					found = true
				end
			end
		end
		assert.is_true(
			found,
			"### 見出し配下のタスクが進捗表示に含まれていない: " .. vim.inspect(virt_lines)
		)
	end)
end)
