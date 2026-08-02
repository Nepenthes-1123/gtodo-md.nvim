-- io.lua から ui/project.lua への層逆流(下位層が上位層を require する状態)を
-- 解消したオブザーバ機構の回帰テスト。
-- io は「書き込みが起きたこと」を通知するだけで、何をするかは購読側が決める。

local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

-- ロードするだけでオブザーバが登録されることを検証するため、
-- ここで明示的に require しておく(実使用では ui/init.lua 経由でロードされる)
require("gtodo-md.ui.project")

describe("io.add_write_observer", function()
	local path
	local calls
	local should_error

	-- オブザーバの解除APIは持たないため、テストファイル全体で1組だけ登録し、
	-- 各テストは calls / should_error 経由で振る舞いを制御する
	io_mod.add_write_observer(function(p)
		table.insert(calls, { name = "first", path = p })
		if should_error then
			error("観測側の意図的なエラー")
		end
	end)
	io_mod.add_write_observer(function(p)
		table.insert(calls, { name = "second", path = p })
	end)

	before_each(function()
		calls = {}
		should_error = false
		path = vim.fn.tempname() .. "_observer.md"
	end)

	after_each(function()
		vim.fn.delete(path)
	end)

	it(
		"write_lines の完了後、登録済みオブザーバが書き込み先の path を引数に呼ばれる",
		function()
			io_mod.write_lines(path, { "# Todo", "" })

			assert.equals(
				2,
				#calls,
				"登録した2つのオブザーバが呼ばれていない: " .. vim.inspect(calls)
			)
			assert.equals("first", calls[1].name)
			assert.equals("second", calls[2].name)
			assert.equals(path, calls[1].path)
			assert.equals(path, calls[2].path)
		end
	)

	it(
		"オブザーバがエラーを投げても write_lines 自体は失敗せず、他のオブザーバも呼ばれる",
		function()
			should_error = true

			local ok = pcall(io_mod.write_lines, path, { "# Todo", "", "- [ ] タスク" })

			assert.is_true(ok, "オブザーバのエラーが write_lines を巻き込んだ")
			assert.are.same(
				{ "# Todo", "", "- [ ] タスク" },
				vim.fn.readfile(path),
				"ディスクへの書き込みが行われていない"
			)
			assert.equals(
				2,
				#calls,
				"先行オブザーバのエラーで後続が呼ばれなくなった: " .. vim.inspect(calls)
			)
			assert.equals("second", calls[2].name)
		end
	)
end)

describe("ui.project のオブザーバ登録", function()
	local data_dir, proj_buf
	local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })

		io_mod.write_lines(data_dir .. "/inbox.md", { "# Inbox", "" })

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
		vim.api.nvim_buf_clear_namespace(proj_buf, ns_id, 0, -1)
	end)

	after_each(function()
		if proj_buf and vim.api.nvim_buf_is_valid(proj_buf) then
			vim.api.nvim_buf_delete(proj_buf, { force = true })
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it(
		"todo.md への書き込みで、render_project_tasks を直接呼ばずとも進捗表示が更新される",
		function()
			io_mod.write_lines(data_dir .. "/todo.md", {
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] タスクA +myproj",
				"",
			})

			local marks = vim.api.nvim_buf_get_extmarks(proj_buf, ns_id, 0, -1, { details = true })
			assert.equals(1, #marks, "書き込み後に進捗のextmarkが描画されていない")

			local found = false
			for _, vline in ipairs(marks[1][4].virt_lines) do
				for _, chunk in ipairs(vline) do
					if chunk[1]:find("タスクA", 1, true) then
						found = true
					end
				end
			end
			assert.is_true(
				found,
				"書き込んだタスクが進捗表示に含まれていない: "
					.. vim.inspect(marks[1][4].virt_lines)
			)
		end
	)

	it("done.md への書き込みでは進捗表示を更新しない(対象は inbox.md / todo.md のみ)", function()
		io_mod.write_lines(data_dir .. "/done.md", {
			"# Done",
			"",
			"## 2026-08",
			"",
			"- [x] 完了タスク +myproj done:2026-08-02",
			"",
		})

		local marks = vim.api.nvim_buf_get_extmarks(proj_buf, ns_id, 0, -1, {})
		assert.equals(0, #marks, "対象外ファイルへの書き込みで進捗表示が更新された")
	end)
end)
