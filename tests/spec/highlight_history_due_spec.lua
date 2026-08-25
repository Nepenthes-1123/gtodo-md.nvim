-- done.md/cancelled.md 上のタスクは既に完了/キャンセル済みのため、
-- due の相対表示(仮想テキスト。「(3日超過)」等)は意味を持たず、ノイズになる。
-- これらのファイルでは due の仮想テキストのみを抑制し、due 日付文字列自体の
-- 色分けハイライトは todo.md/inbox.md と同様に維持されることを確認する。

local highlight_mod = require("gtodo-md.highlight")
local config = require("gtodo-md.config")

local ns = vim.api.nvim_create_namespace("gtodo_highlights")

local DUE_LINE = "- [x] 完了タスク due:2020-01-01 completed_at:2020-01-02 id:a1b2c3"

local function run_update_and_wait(bufnr)
	highlight_mod.update_highlights(bufnr)
	-- update_highlights は vim.schedule で実処理を遅延させているため、
	-- イベントループを一度回して完了を待つ
	vim.wait(100, function()
		return false
	end)
end

-- virt_text(eol)のextmarkが付与されているかどうかを返す
local function has_virt_text(bufnr)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		if mark[4].virt_text then
			return true
		end
	end
	return false
end

-- due日付文字列自体のハイライト(hl_group、conceal/virt_text以外)が
-- 付与されているかどうかを返す
local function has_due_highlight(bufnr)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		local details = mark[4]
		if details.hl_group and details.hl_group:match("^GTodoDate") then
			return true
		end
	end
	return false
end

describe("highlight.update_highlights: done.md/cancelled.mdでのdue仮想テキスト抑制", function()
	local data_dir, buf

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it("done.md では virt_text が付与されない", function()
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, data_dir .. "/done.md")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { DUE_LINE })

		run_update_and_wait(buf)

		assert.is_false(has_virt_text(buf))
		assert.is_true(has_due_highlight(buf))
	end)

	it("cancelled.md では virt_text が付与されない", function()
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, data_dir .. "/cancelled.md")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { DUE_LINE })

		run_update_and_wait(buf)

		assert.is_false(has_virt_text(buf))
		assert.is_true(has_due_highlight(buf))
	end)

	it("todo.md では従来通り virt_text が付与される(回帰確認)", function()
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, data_dir .. "/todo.md")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { DUE_LINE })

		run_update_and_wait(buf)

		assert.is_true(has_virt_text(buf))
		assert.is_true(has_due_highlight(buf))
	end)
end)
