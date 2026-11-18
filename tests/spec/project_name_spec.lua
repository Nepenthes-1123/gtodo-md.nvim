-- プロジェクトファイルを作るときの名前の確かめ。
--
-- 以前は名前を確かめずに projects/<名前>.md を作っていたため、新しいプロジェクトの入力
-- (ui/prompt.lua) やプロジェクトへのジャンプで `../x` のような名前を使うと、データディレクトリの
-- 外にファイルを作れてしまった。分割 (ui/split.lua) だけは名前を正規化していた。
-- 作るときは正規化 (sanitize_tag) で変わらない名前だけを受け付け、すでにあるファイルはそのまま使う。

local project_mod = require("gtodo-md.ui.project")
local config = require("gtodo-md.config")

describe("ui.project のプロジェクト名", function()
	local data_dir, saved_notify, notifications

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
		saved_notify = vim.notify
		notifications = {}
		vim.notify = function(msg)
			table.insert(notifications, msg)
		end
	end)

	after_each(function()
		vim.notify = saved_notify
		vim.fn.delete(data_dir, "rf")
	end)

	it("正規化で変わらない名前だけを作ってよい名前とする", function()
		assert.are.same({ true }, { project_mod.check_new_tag("site-renewal") })
		assert.are.same({ true }, { project_mod.check_new_tag("日本語.v2") })
		assert.are.same({ false, "outside" }, { project_mod.check_new_tag("../outside") })
		assert.are.same({ false, "a-b" }, { project_mod.check_new_tag("a b") })
		assert.are.same({ false, "con_proj" }, { project_mod.check_new_tag("con") })
		assert.are.same({ false }, { project_mod.check_new_tag("...") })
		assert.are.same({ false }, { project_mod.check_new_tag("") })
	end)

	it("データディレクトリの外を指す名前ではファイルを作らない", function()
		assert.is_false(project_mod.create_project_file("../outside"))
		assert.are.equal(0, vim.fn.filereadable(data_dir .. "/outside.md"))
		assert.are.equal(0, vim.fn.filereadable(data_dir .. "/projects/../outside.md"))
		assert.is_truthy(notifications[1]:find('use "outside" instead', 1, true), notifications[1])
	end)

	it("パスの区切りを含む名前は、その場所にファイルがあっても扱わない", function()
		vim.fn.writefile({ "# メモ" }, data_dir .. "/notes.md")
		assert.is_false(project_mod.create_project_file("../notes"))
		assert.is_truthy(notifications[1]:find("cannot be used", 1, true))
	end)

	it(
		"プロジェクトへのジャンプは、外を指す名前ではファイルがあっても開かない",
		function()
			vim.fn.writefile({ "# メモ" }, data_dir .. "/notes.md")
			vim.fn.mkdir(data_dir .. "/projects", "p")
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_set_current_buf(buf)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] 作業 +../notes" })
			project_mod.jump_to_project()
			assert.are.equal(buf, vim.api.nvim_get_current_buf(), "no float is opened")
			assert.is_truthy(notifications[1]:find("cannot be used", 1, true))
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	)

	it("プロジェクトへのジャンプでも、外を指す名前ではファイルを作らない", function()
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] 作業 +../outside" })
		project_mod.jump_to_project()
		assert.are.equal(0, vim.fn.filereadable(data_dir .. "/outside.md"))
		assert.are.equal(buf, vim.api.nvim_get_current_buf(), "no float is opened")
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("すでにあるファイルは、作るときの規則に合わない名前でもそのまま使う", function()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		vim.fn.writefile({ "---", "title: メモ", "---" }, data_dir .. "/projects/my notes.md")
		assert.is_true(project_mod.create_project_file("my notes"))
		assert.are.same({}, notifications)
	end)

	it(
		"新しいプロジェクトの入力では、使えない名前のとき直した名前を初期値にして尋ね直す",
		function()
			local saved_input, saved_select = vim.ui.input, vim.ui.select
			local asked = {}
			vim.ui.input = function(opts, on_confirm)
				local prompt = opts.prompt or ""
				if prompt:find("^Description") then
					on_confirm("資料")
				elseif prompt:find("^Due date") then
					on_confirm("")
				elseif prompt:find("^New Project Name") then
					table.insert(asked, opts.default)
					-- 1 回目は外を指す名前、2 回目は初期値 (直した名前) のまま確定する。
					on_confirm(#asked == 1 and "+../outside" or opts.default)
				end
			end
			vim.ui.select = function(_, opts, on_choice)
				if opts.prompt == "Select Project:" then
					on_choice("New Project...")
				else
					on_choice("[Skip]")
				end
			end
			-- snacks が入っていれば vim.ui.input ではなくそちらを使うため、入っていない前提で動かす。
			local saved_snacks = package.loaded["snacks"]
			package.loaded["snacks"] = nil
			local result
			local ok, err = pcall(function()
				require("gtodo-md.ui.prompt").prompt_task(nil, function(task)
					result = task
				end)
			end)
			vim.ui.input, vim.ui.select = saved_input, saved_select
			package.loaded["snacks"] = saved_snacks
			assert.is_true(ok, err)

			assert.are.same({ "", "outside" }, asked)
			assert.are.equal("outside", result.project)
			assert.are.equal(1, vim.fn.filereadable(data_dir .. "/projects/outside.md"))
			assert.are.equal(0, vim.fn.filereadable(data_dir .. "/outside.md"))
		end
	)
end)
