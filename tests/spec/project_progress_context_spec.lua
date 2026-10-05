-- #162 の回帰テスト。
-- task.parse は @context を `@` 付きのまま task.context に格納するが、
-- render_project_tasks がさらに `@` を前置していたため、進捗表示のタスク一覧に
-- `@@office` と出ていた。

local project_mod = require("gtodo-md.ui.project")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("ui.project.render_project_tasks のコンテキスト表示", function()
	local data_dir, proj_buf

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })
		-- 集計キャッシュは inbox/todo の mtime だけで有効性を判定するため、別のテストが
		-- 同じ秒に書いた集計を流用しないよう毎回捨てる。
		project_mod._active_cache = { inbox_mtime = -1, todo_mtime = -1, projects = {} }

		io_mod.write_lines(data_dir .. "/inbox.md", { "# Inbox", "" })
		io_mod.write_lines(data_dir .. "/todo.md", {
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 会議の準備 +myproj @office",
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

	local function task_line_text()
		project_mod.render_project_tasks(proj_buf)

		local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")
		local marks = vim.api.nvim_buf_get_extmarks(proj_buf, ns_id, 0, -1, { details = true })
		assert.equals(1, #marks, "進捗表示のextmarkが1件のはず: " .. vim.inspect(marks))

		for _, vline in ipairs(marks[1][4].virt_lines) do
			local text = ""
			for _, chunk in ipairs(vline) do
				text = text .. chunk[1]
			end
			if text:find("会議の準備", 1, true) then
				return text
			end
		end
		error("タスク行が進捗表示に含まれていない: " .. vim.inspect(marks[1][4].virt_lines))
	end

	it("コンテキストの @ を二重にしない", function()
		local text = task_line_text()
		assert.is_nil(text:find("@@", 1, true), "@ が二重になっている: " .. text)
		assert.is_truthy(text:find(" @office", 1, true), "コンテキストが表示されていない: " .. text)
	end)
end)
