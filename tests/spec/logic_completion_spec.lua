-- #86/#90 根本原因の回帰テスト。
-- move_completed_tasks は get_section_items 経由でトップレベルの items しか
-- 走査しておらず、### 見出し配下で完了したタスクは done.md へ一切繰り込まれ
-- ずに todo.md へ残り続けていた。

local logic_mod = require("gtodo-md.logic")
local io_mod = require("gtodo-md.io")

describe("logic.move_completed_tasks", function()
	local inbox_path, todo_path, done_path, data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		inbox_path = data_dir .. "/inbox.md"
		todo_path = data_dir .. "/todo.md"
		done_path = data_dir .. "/done.md"
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	it("### 見出し配下で完了したタスクもdone.mdへ移動する", function()
		io_mod.write_lines(inbox_path, { "# Inbox", "" })
		io_mod.write_lines(todo_path, {
			"# Todo",
			"",
			"## Today",
			"",
			"### 仕事",
			"- [x] 仕事タスクA(完了)",
			"- [ ] 仕事タスクB",
			"",
		})
		io_mod.write_lines(done_path, { "# Done", "" })

		local moved = logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)
		assert.is_true(moved)

		local updated_todo = io_mod.read_todo_file(todo_path)
		local remaining_has_completed = false
		local remaining_has_pending = false
		for _, item in ipairs(updated_todo.sections["Today"]) do
			if item.type == "task" and item.task.content == "仕事タスクA(完了)" then
				remaining_has_completed = true
			end
			if item.type == "task" and item.task.content == "仕事タスクB" then
				remaining_has_pending = true
			end
		end
		assert.is_false(remaining_has_completed, "完了タスクがtodo.mdに残っている")
		assert.is_true(remaining_has_pending, "未完了タスクが誤って消えている")

		local done_lines = vim.fn.readfile(done_path)
		local found_in_done = false
		for _, l in ipairs(done_lines) do
			if l:find("仕事タスクA%(完了%)") then
				found_in_done = true
			end
		end
		assert.is_true(found_in_done, "完了タスクがdone.mdへ記録されていない")
	end)
end)
