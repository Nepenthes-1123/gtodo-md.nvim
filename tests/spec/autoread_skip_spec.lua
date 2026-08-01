local timer, utils
local worktree = vim.fn.getcwd():gsub("\\", "/")

describe("autoread and timer skip for project files", function()
	before_each(function()
		package.loaded["gtodo-md.utils"] = dofile(worktree .. "/lua/gtodo-md/utils.lua")
		package.loaded["gtodo-md.config"] = dofile(worktree .. "/lua/gtodo-md/config.lua")
		package.loaded["gtodo-md.timer"] = dofile(worktree .. "/lua/gtodo-md/timer.lua")
		-- daily/logic/lock/io は永続状態(キャッシュされたmtime等)を持つため、
		-- テスト間の汚染を避けるためこちらも毎回リロードする
		package.loaded["gtodo-md.lock"] = dofile(worktree .. "/lua/gtodo-md/lock.lua")
		package.loaded["gtodo-md.io"] = dofile(worktree .. "/lua/gtodo-md/io.lua")
		package.loaded["gtodo-md.logic"] = dofile(worktree .. "/lua/gtodo-md/logic/init.lua")
		package.loaded["gtodo-md.daily"] = dofile(worktree .. "/lua/gtodo-md/daily.lua")
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

	-- R1-4: 未保存(dirty)バッファの有無は自動処理の実行可否に影響しなくなった。
	-- should_skip_timer は現在ノーマルモードかどうかのみを見る。
	it(
		"should_skip_timer はノーマルモードでは false を返す(未保存バッファがあっても)",
		function()
			local buf = vim.api.nvim_create_buf(true, false)
			local proj_path = worktree .. "/projects/test_proj_modified.md"
			vim.api.nvim_buf_set_name(buf, proj_path)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "title: Test", "---" })
			vim.bo[buf].modified = true

			assert.is_false(timer.should_skip_timer())

			vim.api.nvim_buf_delete(buf, { force = true })
		end
	)

	it("should_skip_timer はノーマルモード以外では true を返す", function()
		-- headlessでは startinsert が同期的にモードへ反映されないため、
		-- vim.fn.mode を直接差し替えて検証する
		local original_mode = vim.fn.mode
		vim.fn.mode = function()
			return "i"
		end
		local ok, result = pcall(timer.should_skip_timer)
		vim.fn.mode = original_mode

		assert.is_true(ok)
		assert.is_true(result)
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

	-- R1-2/R1-4 回帰テスト: 以前は未保存(dirty)なバッファがあると
	-- handle_buf_enter は自動処理を丸ごとスキップしていたが、現在は
	-- dirty かどうかに関わらず常に処理・保存し、未保存編集も失わない。
	it("handle_buf_enter は未保存(dirty)なバッファでも自動処理を実行し保存する", function()
		local main_mod = require("gtodo-md")
		local config = require("gtodo-md.config")
		local utils_mod = require("gtodo-md.utils")

		local data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })

		-- 日次ロールオーバー分岐に入らないよう、既に今日処理済みとしておく
		utils_mod.write_last_opened(os.date("%Y-%m-%d"))

		vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 既存タスク",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, data_dir .. "/todo.md")

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, data_dir .. "/todo.md")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 既存タスク",
			"- [ ] 手動で追加した未保存タスク",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		})
		vim.bo[buf].modified = true

		main_mod.handle_buf_enter(buf)

		-- dirtyでも常に処理・保存されるため、未保存状態は解消される
		assert.is_false(vim.bo[buf].modified)
		-- 手動で追加した未保存分の内容は失われていない
		local after_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.is_true(vim.tbl_contains(after_lines, "- [ ] 手動で追加した未保存タスク"))

		vim.api.nvim_buf_delete(buf, { force = true })
		vim.fn.delete(data_dir, "rf")
	end)
end)
