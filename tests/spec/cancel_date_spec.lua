-- キャンセル時に `cancelled:` を記録する。
--
-- task.lua は `cancelled:` をパースもシリアライズもするのに、この値を設定する経路が
-- どこにも存在せず、完了時の `completed_at:` と非対称に情報が欠落したまま
-- cancelled.md へ記録されていた。データ破壊ではないが、いつキャンセルしたのかが
-- 記録された瞬間から永久に失われる。

local config = require("gtodo-md.config")

describe("cancel_current_task の cancelled: 記録", function()
	local data_dir
	local saved_data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		config.options.data_dir = saved_data_dir
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	local function cancelled_entry()
		for _, line in ipairs(vim.fn.readfile(data_dir .. "/cancelled.md")) do
			if line:find("- [", 1, true) then
				return line
			end
		end
		return nil
	end

	it("inbox.md からのキャンセルで cancelled: が記録される", function()
		local inbox_path = data_dir .. "/inbox.md"
		vim.fn.writefile({ "# Inbox", "", "- [ ] やめるタスク" }, inbox_path)
		vim.fn.writefile({ "# Cancelled", "" }, data_dir .. "/cancelled.md")

		vim.cmd("edit " .. vim.fn.fnameescape(inbox_path))
		vim.api.nvim_win_set_cursor(0, { 3, 0 })

		require("gtodo-md.editor").cancel_current_task()

		local entry = cancelled_entry()
		assert.is_truthy(entry, "cancelled.md にエントリが記録されていない")
		assert.is_truthy(
			entry:find("cancelled:" .. os.date("%Y-%m-%d"), 1, true),
			"cancelled: が記録されていない: " .. tostring(entry)
		)
	end)

	it("todo.md からのキャンセルでも cancelled: が記録される", function()
		local todo_path = data_dir .. "/todo.md"
		vim.fn.writefile({
			"# Todo",
			"",
			"## " .. config.sections.TODAY,
			"",
			"- [ ] やめるタスク",
			"",
			"## " .. config.sections.NEXT,
			"",
			"## " .. config.sections.WAITING,
			"",
			"## " .. config.sections.SOMEDAY,
			"",
		}, todo_path)
		vim.fn.writefile({ "# Cancelled", "" }, data_dir .. "/cancelled.md")

		vim.cmd("edit " .. vim.fn.fnameescape(todo_path))
		vim.api.nvim_win_set_cursor(0, { 5, 0 })

		require("gtodo-md.editor").cancel_current_task()

		local entry = cancelled_entry()
		assert.is_truthy(entry, "cancelled.md にエントリが記録されていない")
		assert.is_truthy(
			entry:find("cancelled:" .. os.date("%Y-%m-%d"), 1, true),
			"cancelled: が記録されていない: " .. tostring(entry)
		)
	end)

	-- task.lua が読み戻せる形で書かれていること(単なる文字列連結になっていない)
	it("記録された cancelled: は task.lua で読み戻せる", function()
		local inbox_path = data_dir .. "/inbox.md"
		vim.fn.writefile({ "# Inbox", "", "- [ ] やめるタスク +proj due:2026-08-20" }, inbox_path)
		vim.fn.writefile({ "# Cancelled", "" }, data_dir .. "/cancelled.md")

		vim.cmd("edit " .. vim.fn.fnameescape(inbox_path))
		vim.api.nvim_win_set_cursor(0, { 3, 0 })

		require("gtodo-md.editor").cancel_current_task()

		local parsed = require("gtodo-md.task").parse(cancelled_entry())
		assert.is_truthy(parsed)
		assert.are.equal(os.date("%Y-%m-%d"), parsed.cancelled)
		-- 既存のタグを壊していないこと
		assert.are.equal("proj", parsed.project)
		assert.are.equal("2026-08-20", parsed.due)
	end)
end)
