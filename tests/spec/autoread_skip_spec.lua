local timer = require("gtodo-md.timer")

describe("autoread and timer skip for project files", function()
	it("should_skip_timer returns true when a project file in projects/ is modified", function()
		local buf = vim.api.nvim_create_buf(true, false)
		-- パスを projects/test_project.md に設定
		local current_dir = vim.fn.getcwd()
		local proj_path = current_dir .. "/projects/test_project.md"
		vim.api.nvim_buf_set_name(buf, proj_path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "title: Test", "---" })
		vim.bo[buf].modified = true

		local skip = timer.should_skip_timer()
		assert.is_true(skip)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("should_skip_timer returns false when project file is not modified", function()
		local buf = vim.api.nvim_create_buf(true, false)
		local current_dir = vim.fn.getcwd()
		local proj_path = current_dir .. "/projects/test_project.md"
		vim.api.nvim_buf_set_name(buf, proj_path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "title: Test", "---" })
		vim.bo[buf].modified = false

		local skip = timer.should_skip_timer()
		assert.is_false(skip)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("sets autoread option on inbox.md buffer via autocmd", function()
		require("gtodo-md").setup_autocmds()

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/inbox.md")

		vim.api.nvim_exec_autocmds("BufEnter", { group = "GtodoMd", buffer = buf })

		assert.is_true(vim.bo[buf].autoread)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("sets autoread option on projects/*.md buffer via autocmd", function()
		require("gtodo-md").setup_autocmds()

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, "projects/my_project.md")

		vim.api.nvim_exec_autocmds("BufEnter", { group = "GtodoMd", buffer = buf })

		assert.is_true(vim.bo[buf].autoread)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)
end)
