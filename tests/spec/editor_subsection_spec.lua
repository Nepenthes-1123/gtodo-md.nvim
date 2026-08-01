-- #86 / #90 の根本原因回帰テスト。
--
-- 旧実装(サブセクションをネスト構造 {items, subsections} として保持)では、
-- update_task_in_todo が io_mod.get_section_items 経由でトップレベルの
-- items しか見ておらず、### 見出し配下のタスクは常に「見つからない」扱いに
-- なっていた。完了トグル・セクション移動・キャンセルのいずれも失敗し、
-- "Task not found in todo.md." という誤った警告が出ていた。
--
-- サブセクションを構造化データとして扱うのをやめ、### 見出しを他の
-- テキスト行と同じフラットな items 配列の一員にしたことで、この問題は
-- 一箇所の実装ミスではなく構造的に解消される。

local task_mod = require("gtodo-md.task")
local editor_mod = require("gtodo-md.editor")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("editor: ### 見出し配下のタスクに対する操作 (#86, #90)", function()
	local data_dir, todo_path, buf

	local function task_in(items, content)
		for _, item in ipairs(items) do
			if item.type == "task" and item.task.content == content then
				return item.task
			end
		end
		return nil
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
		todo_path = data_dir .. "/todo.md"

		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, todo_path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"# Todo",
			"",
			"## Today",
			"",
			"### 仕事",
			"- [ ] 仕事タスクA due:2025-01-01",
			"- [ ] 仕事タスクB",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		})
		vim.api.nvim_set_current_buf(buf)

		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		for i, l in ipairs(lines) do
			if l:find("仕事タスクA", 1, true) then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				break
			end
		end
	end)

	after_each(function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it("### 見出し配下のタスクを完了トグルできる", function()
		editor_mod.toggle_complete()

		local data = io_mod.read_todo_file(todo_path)
		local found = task_in(data.sections["Today"], "仕事タスクA")
		assert.is_not_nil(found, "仕事タスクA が見当たらない")
		assert.equals("x", found.status)
	end)

	it("### 見出し配下のタスクを別セクションへ移動できる", function()
		local task, row = editor_mod.get_current_task()
		editor_mod._execute_move(task, row, config.sections.NEXT)

		local data = io_mod.read_todo_file(todo_path)
		assert.is_not_nil(
			task_in(data.sections[config.sections.NEXT], "仕事タスクA"),
			"Nextセクションに移動していない"
		)
		assert.is_nil(
			task_in(data.sections["Today"], "仕事タスクA"),
			"元のTodayセクションに残っている"
		)
	end)

	it("### 見出し配下のタスクをキャンセルできる", function()
		editor_mod.cancel_current_task()

		local data = io_mod.read_todo_file(todo_path)
		assert.is_nil(
			task_in(data.sections["Today"], "仕事タスクA"),
			"キャンセル後もtodo.mdに残っている"
		)

		local cancelled_lines = vim.fn.readfile(data_dir .. "/cancelled.md")
		local found_in_cancelled = false
		for _, l in ipairs(cancelled_lines) do
			if l:find("仕事タスクA", 1, true) then
				found_in_cancelled = true
			end
		end
		assert.is_true(found_in_cancelled, "cancelled.md に記録されていない")
	end)
end)
