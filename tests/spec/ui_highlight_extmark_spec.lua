-- Queue / カンバンのハイライト適用が、非推奨の nvim_buf_add_highlight() から
-- nvim_buf_set_extmark() へ移行しても同じ extmark になることを固定する。
--
-- nvim_buf_add_highlight() は Neovim 0.11 で非推奨になり、代替として
-- vim.hl.range() と nvim_buf_set_extmark() の2つが示されている(:h deprecated-0.11)。
-- このプラグインは後者を採用している。理由は優先度で、vim.hl.range() は
-- vim.hl.priorities.user(200)を明示的に設定するため、旧APIの既定値から変わり、
-- 他のハイライトとの重なり順が黙って入れ替わりうる。
--
-- 検証する契約は2つ:
--   1. 「行全体」のハイライトが行末までではなく**次の行の先頭まで**伸びること
--      (旧APIの end_col = -1 と同じ表現)
--   2. 優先度が nvim_buf_set_extmark の既定値のままであること
-- 2 は 4096 という具体値を直接書かず、同じAPIで作った参照 extmark と比較する
-- (Neovim 側が既定値を変えてもテストが壊れないようにするため)。

local config = require("gtodo-md.config")

-- 優先度を指定せずに作った extmark の既定優先度を実測で得る。
local function default_extmark_priority()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
	local ns = vim.api.nvim_create_namespace("gtodo_priority_reference")
	vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 1, hl_group = "Comment" })
	local mark = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1]
	vim.api.nvim_buf_delete(buf, { force = true })
	return mark[4].priority
end

local function marks_of(buf, ns_name)
	local ns = vim.api.nvim_create_namespace(ns_name)
	return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

describe("ui: ハイライト適用の extmark", function()
	local data_dir
	local orig_columns, orig_lines

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 期限付きタスク due:2030-01-01 id:aaa111",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, data_dir .. "/todo.md")
		vim.fn.writefile({ "# Done", "" }, data_dir .. "/done.md")
		config.setup({ data_dir = data_dir })

		orig_columns, orig_lines = vim.o.columns, vim.o.lines
		vim.o.columns = 200
		vim.o.lines = 50
	end)

	after_each(function()
		require("gtodo-md.ui.kanban").close_kanban()
		require("gtodo-md.ui.float").close_current_float()
		vim.o.columns, vim.o.lines = orig_columns, orig_lines
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it("Queue の行ハイライトは次の行の先頭まで伸び、既定の優先度を保つ", function()
		require("gtodo-md.ui.queue").open_queue()
		local buf = vim.api.nvim_get_current_buf()

		local marks = marks_of(buf, "gtodo_queue")
		assert.is_true(#marks > 0, "Queue のハイライトが1つも適用されていない")

		local expected_priority = default_extmark_priority()
		for _, mark in ipairs(marks) do
			local row, col, d = mark[2], mark[3], mark[4]
			assert.are.same(0, col, "行ハイライトの開始列が0でない")
			assert.are.same(row + 1, d.end_row, "行ハイライトが次の行の先頭まで伸びていない")
			assert.are.same(0, d.end_col, "行ハイライトの終端列が0でない")
			assert.are.same(
				expected_priority,
				d.priority,
				"優先度が set_extmark の既定値から変わっている(vim.hl.range へ差し替わった可能性)"
			)
		end
	end)

	it("カンバンの選択カードの罫線ハイライトも同じ表現と優先度を使う", function()
		local kanban = require("gtodo-md.ui.kanban")
		kanban.open_kanban()

		-- Today 列(カードが1枚ある列)のバッファを探す
		local target
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(win).relative ~= "" then
				local buf = vim.api.nvim_win_get_buf(win)
				if #marks_of(buf, "gtodo_kanban_selected") > 0 then
					target = buf
					break
				end
			end
		end
		assert.is_truthy(target, "選択カードのハイライトを持つカンバン列が見つからない")

		local expected_priority = default_extmark_priority()
		local full_line_marks = 0
		for _, mark in ipairs(marks_of(target, "gtodo_kanban_selected")) do
			local row, d = mark[2], mark[4]
			assert.are.same(
				expected_priority,
				d.priority,
				"優先度が set_extmark の既定値から変わっている(vim.hl.range へ差し替わった可能性)"
			)
			if d.end_row == row + 1 and d.end_col == 0 then
				full_line_marks = full_line_marks + 1
			end
		end

		-- カードの上端・下端の罫線行は旧APIで end_col = -1(行末まで)を使っていた箇所。
		assert.is_true(
			full_line_marks >= 2,
			"カード上下端の行全体ハイライトが次の行の先頭まで伸びていない: "
				.. full_line_marks
		)
	end)
end)
