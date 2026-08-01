-- id: タグが conceal で隠されること、および concealcursor によって
-- カーソルがその行にある間は編集可能な状態(見える状態)に戻ることを確認する。
-- conceal はあくまで表示上の機能であり、バッファの中身は一切変更しない。

local highlight_mod = require("gtodo-md.highlight")

local ns = vim.api.nvim_create_namespace("gtodo_highlights")

describe("highlight: id:タグのconceal表示", function()
	local buf

	before_each(function()
		buf = vim.api.nvim_create_buf(false, true)
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	local function run_update_and_wait(bufnr)
		highlight_mod.update_highlights(bufnr)
		-- update_highlights は vim.schedule で実処理を遅延させているため、
		-- イベントループを一度回して完了を待つ
		vim.wait(100, function()
			return false
		end)
	end

	it('id:タグの範囲にconceal=""のextmarkが設定される', function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] タスク due:2025-01-01 id:a1b2c3" })
		run_update_and_wait(buf)

		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
		local found = false
		for _, mark in ipairs(marks) do
			local details = mark[4]
			if details.conceal == "" then
				found = true
				local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
				local concealed_text = line:sub(mark[3] + 1, details.end_col)
				assert.are.same(" id:a1b2c3", concealed_text)
			end
		end
		assert.is_true(found, "id:タグのconceal extmarkが見つからない")
	end)

	it("id:タグが無い行にはconceal extmarkが付かない", function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] IDなしタスク due:2025-01-01" })
		run_update_and_wait(buf)

		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
		for _, mark in ipairs(marks) do
			assert.is_nil(mark[4].conceal)
		end
	end)

	it("バッファの中身自体は変更されない(表示上の機能に過ぎない)", function()
		local line = "- [ ] タスク id:a1b2c3"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
		run_update_and_wait(buf)

		assert.are.same({ line }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)
end)

describe("highlight.setup: conceallevel/concealcursorの設定", function()
	it('BufWinEnterでdata_dir配下のバッファにconceallevel=2, concealcursor=""を設定する', function()
		local config = require("gtodo-md.config")
		local data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })

		highlight_mod.setup()

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, data_dir .. "/todo.md")
		-- nvim_open_win でバッファを新しいウィンドウに表示すると、実際に
		-- BufWinEnter が発火する(手動発火に頼らず、実際の利用に近い形で検証する)
		local win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = 10,
			height = 5,
			row = 0,
			col = 0,
		})

		assert.are.same(2, vim.wo[win].conceallevel)
		assert.are.same("", vim.wo[win].concealcursor)

		vim.api.nvim_win_close(win, true)
		vim.fn.delete(data_dir, "rf")
	end)
end)
