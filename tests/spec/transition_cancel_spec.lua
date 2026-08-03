-- タスクの状態遷移: キャンセルの仕様テスト
--
-- 既存の editor_subsection_spec.lua は「### 見出し配下のタスクをキャンセル
-- できる」のみで、キャンセルの基本仕様(cancelled.md への記録内容、
-- ファイル未作成時の生成、タスク行でない場所での操作)は未カバー。

local editor_mod = require("gtodo-md.editor")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("状態遷移: キャンセル", function()
	local data_dir, todo_path, inbox_path, cancelled_path, buf

	local function task_in(items, content)
		for _, item in ipairs(items or {}) do
			if item.type == "task" and item.task.content == content then
				return item.task
			end
		end
		return nil
	end

	local function put_cursor_on(needle)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		for i, l in ipairs(lines) do
			if l:find(needle, 1, true) then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				return i
			end
		end
		error("カーソル対象の行が見つからない: " .. needle)
	end

	local function standard_todo(tasks)
		local lines = { "# Todo", "" }
		for _, key in ipairs({ "TODAY", "NEXT", "WAITING", "SOMEDAY" }) do
			local name = config.sections[key]
			table.insert(lines, "## " .. name)
			table.insert(lines, "")
			for _, l in ipairs((tasks or {})[name] or {}) do
				table.insert(lines, l)
			end
			table.insert(lines, "")
		end
		return lines
	end

	local function open_buf(path, lines)
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_current_buf(buf)
	end

	local function cancelled_lines()
		if vim.fn.filereadable(cancelled_path) == 0 then
			return {}
		end
		return vim.fn.readfile(cancelled_path)
	end

	local function count_matching(lines, needle)
		local n = 0
		for _, l in ipairs(lines) do
			if l:find(needle, 1, true) then
				n = n + 1
			end
		end
		return n
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
		todo_path = data_dir .. "/todo.md"
		inbox_path = data_dir .. "/inbox.md"
		cancelled_path = data_dir .. "/cancelled.md"
	end)

	after_each(function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		buf = nil
		vim.fn.delete(data_dir, "rf")
	end)

	it("todo.md のタスクをキャンセルすると cancelled.md へ移り todo.md から消える", function()
		open_buf(todo_path, standard_todo({ [config.sections.NEXT] = { "- [ ] タスクA" } }))
		put_cursor_on("タスクA")

		editor_mod.cancel_current_task()

		local data = io_mod.read_todo_file(todo_path)
		assert.is_nil(task_in(data.sections[config.sections.NEXT], "タスクA"), "todo.md に残っている")
		assert.equals(1, count_matching(cancelled_lines(), "タスクA"), "cancelled.md に記録されていない")
	end)

	it("cancelled.md が存在しなくても生成されて追記される", function()
		assert.equals(0, vim.fn.filereadable(cancelled_path), "前提: cancelled.md がまだ無いこと")

		open_buf(todo_path, standard_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } }))
		put_cursor_on("タスクA")

		editor_mod.cancel_current_task()

		assert.equals(1, vim.fn.filereadable(cancelled_path), "cancelled.md が生成されていない")
		local lines = cancelled_lines()
		assert.equals(1, count_matching(lines, "# Cancelled"), "トップヘッダーが無い")
		assert.equals(1, count_matching(lines, "タスクA"), "タスクが記録されていない")
	end)

	it("キャンセルしたタスクは内容とタグを保ったまま記録される", function()
		open_buf(
			todo_path,
			standard_todo({ [config.sections.NEXT] = { "- [ ] (B) タスクA due:2026-08-10 @office +Proj" } })
		)
		put_cursor_on("タスクA")

		editor_mod.cancel_current_task()

		local lines = cancelled_lines()
		local entry
		for _, l in ipairs(lines) do
			if l:find("タスクA", 1, true) then
				entry = l
			end
		end
		assert.is_not_nil(entry, "cancelled.md にタスクが無い")
		assert.is_not_nil(entry:find("(B)", 1, true), "優先度が失われている: " .. entry)
		assert.is_not_nil(entry:find("due:2026-08-10", 1, true), "due が失われている: " .. entry)
		assert.is_not_nil(entry:find("@office", 1, true), "context が失われている: " .. entry)
		assert.is_not_nil(entry:find("+Proj", 1, true), "project が失われている: " .. entry)
	end)

	it("inbox.md のタスクもキャンセルできる", function()
		open_buf(inbox_path, { "# Inbox", "", "- [ ] 受信タスク", "" })
		put_cursor_on("受信タスク")

		editor_mod.cancel_current_task()

		local remaining = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.equals(0, count_matching(remaining, "受信タスク"), "inbox.md に残っている")
		assert.equals(
			1,
			count_matching(cancelled_lines(), "受信タスク"),
			"cancelled.md に記録されていない"
		)
	end)

	it("タスク行でない行でキャンセルしても cancelled.md に何も追記されない", function()
		open_buf(todo_path, standard_todo({ [config.sections.NEXT] = { "- [ ] タスクA" } }))
		put_cursor_on("## " .. config.sections.NEXT)

		editor_mod.cancel_current_task()

		assert.equals(0, count_matching(cancelled_lines(), "タスクA"), "タスクが誤って記録されている")

		local data = io_mod.read_todo_file(todo_path)
		assert.is_not_nil(
			task_in(data.sections[config.sections.NEXT], "タスクA"),
			"todo.md からタスクが消えている"
		)
	end)
end)
