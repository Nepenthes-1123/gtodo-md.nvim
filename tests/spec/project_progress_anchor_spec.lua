-- #155 の回帰テスト。
-- 進捗の virtual text をバッファ最終行の下に置いていたため、本文が伸びると
-- フロートの表示範囲から押し出され、スクロールしないと進捗が見えなくなっていた。
-- frontmatter の直下へ固定する。

local project_mod = require("gtodo-md.ui.project")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("ui.project._progress_anchor", function()
	it("frontmatter がある場合は終端 `---` の下へ寄せる", function()
		local row, above = project_mod._progress_anchor({
			"---",
			"title: Test",
			"tag: myproj",
			"---",
			"",
			"## Overview",
		})
		-- 終端 `---` は4行目(1-indexed) = row 3(0-indexed)
		assert.equals(3, row)
		assert.is_false(above)
	end)

	it("frontmatter しか無いファイルでも終端 `---` の下を指す", function()
		local row, above = project_mod._progress_anchor({ "---", "tag: myproj", "---" })
		assert.equals(2, row)
		assert.is_false(above)
	end)

	it("frontmatter が無ければ先頭行の上へ寄せる", function()
		local row, above = project_mod._progress_anchor({ "# Project", "", "## Overview" })
		assert.equals(0, row)
		assert.is_true(above)
	end)

	it("frontmatter が閉じていなければ先頭行の上へ寄せる", function()
		local row, above = project_mod._progress_anchor({ "---", "tag: myproj", "## Overview" })
		assert.equals(0, row)
		assert.is_true(above)
	end)

	it("空のバッファでも先頭行の上を指す", function()
		local row, above = project_mod._progress_anchor({})
		assert.equals(0, row)
		assert.is_true(above)
	end)
end)

describe("ui.project.render_project_tasks の配置", function()
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
			"- [ ] タスクA +myproj",
			"",
		})

		local lines = {
			"---",
			"title: Test Project",
			"tag: myproj",
			"created: 2025-01-01",
			"status: active",
			"members: []",
			"---",
			"",
			"## Overview",
		}
		-- 本文が長いプロジェクトファイル(#155 の再現条件)
		for i = 1, 200 do
			table.insert(lines, "本文 " .. i)
		end

		proj_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(proj_buf, data_dir .. "/projects/myproj.md")
		vim.api.nvim_buf_set_lines(proj_buf, 0, -1, false, lines)
	end)

	after_each(function()
		if proj_buf and vim.api.nvim_buf_is_valid(proj_buf) then
			vim.api.nvim_buf_delete(proj_buf, { force = true })
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it("本文が長くても frontmatter 直下に描画され、最終行には置かれない", function()
		project_mod.render_project_tasks(proj_buf)

		local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")
		local marks = vim.api.nvim_buf_get_extmarks(proj_buf, ns_id, 0, -1, { details = true })
		assert.equals(1, #marks, "進捗表示のextmarkが1件のはず: " .. vim.inspect(marks))

		-- 終端 `---` は7行目(1-indexed) = row 6(0-indexed)
		assert.equals(6, marks[1][2], "frontmatter 直下に置かれていない")
		assert.is_false(marks[1][4].virt_lines_above)
	end)

	it("区切り線と空行はブロックの後ろに置かれる", function()
		project_mod.render_project_tasks(proj_buf)

		local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")
		local marks = vim.api.nvim_buf_get_extmarks(proj_buf, ns_id, 0, -1, { details = true })
		local virt_lines = marks[1][4].virt_lines

		assert.is_true(
			virt_lines[1][1][1]:find("プロジェクト進捗", 1, true) ~= nil,
			"先頭が進捗バーではない: " .. vim.inspect(virt_lines)
		)
		assert.is_true(
			virt_lines[#virt_lines - 1][1][1]:find("----", 1, true) ~= nil,
			"末尾から2行目が区切り線ではない: " .. vim.inspect(virt_lines)
		)
		assert.equals("", virt_lines[#virt_lines][1][1])
	end)
end)
