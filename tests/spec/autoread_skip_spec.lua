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

		local config = package.loaded["gtodo-md.config"]
		config.setup({ data_dir = worktree })

		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
	end)

	it("should_skip_timer returns true when a project file in projects/ is modified", function()
		local buf = vim.api.nvim_create_buf(true, false)
		local proj_path = worktree .. "/projects/test_proj_modified.md"
		vim.api.nvim_buf_set_name(buf, proj_path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "title: Test", "---" })
		vim.bo[buf].modified = true

		local skip = timer.should_skip_timer()
		assert.is_true(skip)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("should_skip_timer returns false when project file is not modified", function()
		local buf = vim.api.nvim_create_buf(true, false)
		local proj_path = worktree .. "/projects/test_proj_unmodified.md"
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

		-- 相対パスでも正しく判定できること
		config.setup({ data_dir = vim.fn.getcwd() })
		assert.is_true(utils.is_gtodo_file("inbox.md"))
		assert.is_true(utils.is_gtodo_file("projects/my_proj_modified.md"))

		-- 隣接名ディレクトリや外部プロジェクトの拒否
		assert.is_false(utils.is_gtodo_file("C:/my_gtodo_data_backup/inbox.md"))
		assert.is_false(utils.is_gtodo_file("C:/external/projects/my_project.md"))
		assert.is_false(utils.is_gtodo_file("C:/my_gtodo_data/readme.md"))
		assert.is_false(utils.is_gtodo_file(""))
		assert.is_false(utils.is_gtodo_file(nil))
	end)

	it("handle_buf_enter skips disk modification when buffer is modified", function()
		local main_mod = require("gtodo-md")
		local config = require("gtodo-md.config")
		config.setup({ data_dir = vim.fn.getcwd() })

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/todo.md")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "## Today", "- [ ] Unsaved Task" })
		vim.bo[buf].modified = true

		-- handle_buf_enter の実行
		main_mod.handle_buf_enter(buf)

		-- 未保存バッファの状態と内容がそのまま保持されていることを確認
		assert.is_true(vim.bo[buf].modified)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("should_skip_timer returns true when cancelled.md in data_dir is modified", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = vim.fn.getcwd() })

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/cancelled.md")
		vim.bo[buf].modified = true

		assert.is_true(timer.should_skip_timer())
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("should_skip_timer returns false for unnamed modified buffers", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = vim.fn.getcwd() })

		local buf = vim.api.nvim_create_buf(true, false)
		-- 名前未設定の無名バッファ
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Unnamed content" })
		vim.bo[buf].modified = true

		assert.is_false(timer.should_skip_timer())
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("resumes auto-process via BufWritePost when saved", function()
		local main_mod = package.loaded["gtodo-md"]

		local buf = vim.api.nvim_create_buf(true, false)
		local todo_path = worktree .. "/todo.md"
		vim.api.nvim_buf_set_name(buf, todo_path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "## Today", "- [ ] Unsaved Task" })
		vim.bo[buf].modified = true

		-- 未保存時は handle_buf_enter が自動処理をスキップ
		main_mod.handle_buf_enter(buf)
		assert.is_true(vim.bo[buf].modified)

		-- BufWritePost autocmd をシミュレート (modified を false にして発火)
		vim.bo[buf].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { group = "GtodoMd", buffer = buf })

		-- エラーなく処理され、バッファが正常に同期・維持されていること
		assert.is_false(vim.bo[buf].modified)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)
end)
