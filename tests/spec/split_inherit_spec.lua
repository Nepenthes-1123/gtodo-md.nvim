-- 分割を確定したとき、サブタスクが親タスクから何を引き継ぐか。
--
-- 以前は親の行の文字列から `key:value` と `#語` を拾って子の行へ足していたため、本文中の
-- `ratio:3` や `#memo` までタグとして複製されていた。今は task.parse で読んだ項目
-- (プロジェクト・コンテキスト・期日・待ち先・作成日・from:) だけを引き継ぐ。

local config = require("gtodo-md.config")

describe("split の確定で引き継ぐ項目", function()
	local data_dir, saved_input, saved_notify

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
		saved_input = vim.ui.input
		saved_notify = vim.notify
		vim.notify = function() end
	end)

	after_each(function()
		vim.ui.input = saved_input
		vim.notify = saved_notify
		vim.cmd("silent! %bwipeout!")
		vim.fn.delete(data_dir, "rf")
	end)

	it("本文中の key:value や #語 は複製せず、プロジェクトなどの項目を引き継ぐ", function()
		local path = data_dir .. "/todo.md"
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] (A) 発表 ratio:3 #memo +talk @office due:2026-12-01 id:aaaaaa",
		}, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local source = vim.api.nvim_get_current_buf()
		vim.api.nvim_win_set_cursor(0, { 5, 0 })
		vim.ui.input = function(_, on_confirm)
			on_confirm("launch")
		end

		require("gtodo-md.ui.split").split_current_task()
		vim.cmd("stopinsert")
		local scratch = vim.api.nvim_get_current_buf()
		assert.are_not.equal(source, scratch)
		vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "- [ ] 資料", "- [ ] 練習 @home" })
		vim.fn.maparg("g<CR>", "n", false, true).callback()

		local lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
		assert.are.same({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 資料 +launch @office due:2026-12-01",
			"- [ ] 練習 @home +launch due:2026-12-01",
		}, lines)
		assert.are.equal(1, vim.fn.filereadable(data_dir .. "/projects/launch.md"))
	end)
end)
