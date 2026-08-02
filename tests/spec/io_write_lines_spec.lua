-- #57 回帰テスト: write_lines が nvim_buf_call + :write を使わなくなったこと、
-- および R1-2: バッファが未保存(dirty)でも常に反映・保存されることを確認する。

local io_mod = require("gtodo-md.io")

describe("io.write_lines", function()
	local path

	before_each(function()
		path = vim.fn.tempname() .. "_write_lines.md"
	end)

	after_each(function()
		vim.fn.delete(path)
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == path then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
	end)

	it("バッファが開いていない場合、ファイルへ直接書き込む", function()
		io_mod.write_lines(path, { "# Todo", "", "- [ ] タスク" })
		local disk_lines = vim.fn.readfile(path)
		assert.are.same({ "# Todo", "", "- [ ] タスク" }, disk_lines)
	end)

	it(
		"バッファが開いていてクリーンな場合、バッファとディスクの両方に反映され未保存状態にならない",
		function()
			vim.fn.writefile({ "# Todo", "" }, path)
			vim.cmd("edit " .. vim.fn.fnameescape(path))
			local buf = vim.api.nvim_get_current_buf()
			assert.is_false(vim.bo[buf].modified)

			io_mod.write_lines(path, { "# Todo", "", "- [ ] 新規タスク" })

			assert.are.same({ "# Todo", "", "- [ ] 新規タスク" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
			assert.is_false(vim.bo[buf].modified)
			assert.are.same({ "# Todo", "", "- [ ] 新規タスク" }, vim.fn.readfile(path))
		end
	)

	it(
		"バッファが未保存(dirty)でも、その内容を保持したままディスクへ保存される (R1-2)",
		function()
			vim.fn.writefile({ "# Todo", "" }, path)
			vim.cmd("edit " .. vim.fn.fnameescape(path))
			local buf = vim.api.nvim_get_current_buf()

			-- ユーザーの未保存編集
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Todo", "", "- [ ] 手動タスク" })
			assert.is_true(vim.bo[buf].modified)

			-- 自動処理: 手動タスクを含む内容をもとに新規タスクを追記
			local merged = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			table.insert(merged, "- [ ] 自動タスク")
			io_mod.write_lines(path, merged)

			-- dirtyだったにも関わらず、常に保存される(以前は was_modified なら保存をスキップしていた)
			assert.is_false(vim.bo[buf].modified)
			assert.are.same(merged, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
			assert.are.same(merged, vim.fn.readfile(path))
		end
	)

	it(":write を使わないため BufWritePre/BufWritePost を発火させない (#57)", function()
		vim.fn.writefile({ "# Todo", "" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()

		local fired = false
		local group = vim.api.nvim_create_augroup("TestWriteLinesNoAutocmd", { clear = true })
		vim.api.nvim_create_autocmd({ "BufWritePre", "BufWritePost" }, {
			group = group,
			buffer = buf,
			callback = function()
				fired = true
			end,
		})

		io_mod.write_lines(path, { "# Todo", "", "- [ ] タスク" })

		assert.is_false(fired, "write_lines が :write 相当のautocmdを発火させた")
		vim.api.nvim_del_augroup_by_id(group)
	end)

	it(
		"write_lines後、Vim内部のmtime追跡が同期されるため後続の変更でW12相当の誤検知が起きない",
		function()
			vim.fn.writefile({ "# Todo", "" }, path)
			vim.cmd("edit " .. vim.fn.fnameescape(path))
			local buf = vim.api.nvim_get_current_buf()

			io_mod.write_lines(path, { "# Todo", "", "- [ ] タスク" })

			-- write_lines 後、さらにバッファを編集してdirtyにする
			-- (W12/FileChangedShellはバッファがdirtyな時にのみ問題になる)
			vim.api.nvim_buf_set_lines(
				buf,
				0,
				-1,
				false,
				{ "# Todo", "", "- [ ] タスク", "- [ ] 別の未保存編集" }
			)
			assert.is_true(vim.bo[buf].modified)

			local fcs_fired = false
			local group = vim.api.nvim_create_augroup("TestFileChangedShell", { clear = true })
			vim.api.nvim_create_autocmd("FileChangedShell", {
				group = group,
				buffer = buf,
				callback = function()
					fcs_fired = true
				end,
			})

			vim.cmd("silent! checktime " .. buf)

			assert.is_false(
				fcs_fired,
				"write_lines自身の書き込みが外部変更と誤認され、FileChangedShellが発火した(W12相当)"
			)
			vim.api.nvim_del_augroup_by_id(group)
		end
	)

	it("バッファの fileformat が dos の場合、CRLFで保存される", function()
		vim.fn.writefile({ "# Todo", "" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].fileformat = "dos"

		io_mod.write_lines(path, { "# Todo", "", "- [ ] タスク" })

		local f = io.open(path, "rb")
		local content = f:read("*all")
		f:close()
		assert.is_not_nil(content:find("\r\n"), "CRLFで保存されていない")
	end)
end)
