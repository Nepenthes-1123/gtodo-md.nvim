local timer, utils
local worktree = vim.fn.getcwd():gsub("\\", "/")

describe("autoread and timer skip for project files", function()
	before_each(function()
		package.loaded["gtodo-md.utils"] = dofile(worktree .. "/lua/gtodo-md/utils.lua")
		package.loaded["gtodo-md.config"] = dofile(worktree .. "/lua/gtodo-md/config.lua")
		package.loaded["gtodo-md.timer"] = dofile(worktree .. "/lua/gtodo-md/timer.lua")
		package.loaded["gtodo-md.init"] = dofile(worktree .. "/lua/gtodo-md/init.lua")
		package.loaded["gtodo-md"] = package.loaded["gtodo-md.init"]
		utils = package.loaded["gtodo-md.utils"]
		timer = package.loaded["gtodo-md.timer"]
	end)
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

	it("sets autoread option on inbox.md buffer in data_dir via autocmd", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = vim.fn.getcwd() })
		require("gtodo-md").setup_autocmds()

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/inbox.md")

		vim.api.nvim_exec_autocmds("BufEnter", { group = "GtodoMd", buffer = buf })

		assert.is_true(vim.bo[buf].autoread)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("sets autoread option on projects/*.md buffer in data_dir via autocmd", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = vim.fn.getcwd() })
		require("gtodo-md").setup_autocmds()

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/projects/my_project.md")

		vim.api.nvim_exec_autocmds("BufEnter", { group = "GtodoMd", buffer = buf })

		assert.is_true(vim.bo[buf].autoread)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("utils.is_gtodo_file correctly identifies gtodo files and excludes external files", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = "C:/my_gtodo_data" })

		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/inbox.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/todo.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/done.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/cancelled.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/projects/my_project.md"))

		-- 外部プロジェクトや対象外ファイル
		assert.is_false(utils.is_gtodo_file("C:/external/projects/my_project.md"))
		assert.is_false(utils.is_gtodo_file("C:/my_gtodo_data/readme.md"))
		assert.is_false(utils.is_gtodo_file(""))
		assert.is_false(utils.is_gtodo_file(nil))
	end)
end)
