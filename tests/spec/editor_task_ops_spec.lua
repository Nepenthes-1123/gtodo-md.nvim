-- editor.lua に追加した、カーソル位置に依存しないタスク操作関数のテスト。
--
-- M.move_task_between_sections / M.toggle_task_complete は、既存のカーソル版
-- (M._execute_move の todo.md 分岐 / M.toggle_complete の todo.md 分岐)から
-- 切り出した共通コアであり、ui/kanban.lua が(カレントバッファ・カーソルを
-- 経由せず)直接呼び出すために追加した。カーソル版の既存の挙動は
-- transition_move_spec.lua / transition_complete_spec.lua で既にカバーされて
-- いるため、ここでは「カーソルに依存せず動くこと」自体を検証する。

local editor_mod = require("gtodo-md.editor")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("editor: カーソル非依存のタスク操作(Kanban向け)", function()
	local data_dir, todo_path

	local function task_in(items, content)
		for _, item in ipairs(items or {}) do
			if item.type == "task" and item.task.content == content then
				return item.task
			end
		end
		return nil
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

	local function with_ui_input(answer, fn)
		local original = vim.ui.input
		vim.ui.input = function(_, on_confirm)
			on_confirm(answer)
		end
		local ok, err = pcall(fn)
		vim.ui.input = original
		if not ok then
			error(err)
		end
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
		todo_path = data_dir .. "/todo.md"
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	describe("M.move_task_between_sections", function()
		it("開いているバッファ/カーソルが無くてもセクション間を移動できる", function()
			io_mod.write_lines(todo_path, standard_todo({ [config.sections.NEXT] = { "- [ ] タスクA" } }))
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.NEXT], "タスクA")

			local moved = editor_mod.move_task_between_sections(t, config.sections.NEXT, config.sections.TODAY)
			assert.is_true(moved)

			local after = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(task_in(after.sections[config.sections.TODAY], "タスクA"))
			assert.is_nil(task_in(after.sections[config.sections.NEXT], "タスクA"))
		end)

		it("同一セクションへの移動はno-opでfalseを返す", function()
			io_mod.write_lines(todo_path, standard_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } }))
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.TODAY], "タスクA")

			local moved = editor_mod.move_task_between_sections(t, config.sections.TODAY, config.sections.TODAY)
			assert.is_false(moved)
		end)

		it("Waiting→Waitingはwait:のみを更新する", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({ [config.sections.WAITING] = { "- [ ] タスクA wait:田中さん" } })
			)
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.WAITING], "タスクA")
			t.wait = "鈴木さん"

			local updated = editor_mod.move_task_between_sections(t, config.sections.WAITING, config.sections.WAITING)
			assert.is_true(updated)

			local after = io_mod.read_todo_file(todo_path)
			local moved = task_in(after.sections[config.sections.WAITING], "タスクA")
			assert.equals("鈴木さん", moved.wait)
			assert.equals(1, #after.sections[config.sections.WAITING])
		end)

		it("見つからないタスクを渡すと false を返し通知する", function()
			io_mod.write_lines(todo_path, standard_todo())
			local fake = require("gtodo-md.task").parse("- [ ] 存在しないタスク")

			local moved = editor_mod.move_task_between_sections(fake, config.sections.NEXT, config.sections.TODAY)
			assert.is_false(moved)
		end)
	end)

	describe("M.toggle_task_complete", function()
		it("未完了タスクを完了にし、completed_atを設定する", function()
			io_mod.write_lines(todo_path, standard_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } }))
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.TODAY], "タスクA")

			local ok = editor_mod.toggle_task_complete(t, config.sections.TODAY)
			assert.is_true(ok)

			local after = io_mod.read_todo_file(todo_path)
			local toggled = task_in(after.sections[config.sections.TODAY], "タスクA")
			assert.equals("x", toggled.status)
			assert.is_not_nil(toggled.completed_at)
		end)

		it("完了済みタスクを未完了へ戻す", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({ [config.sections.TODAY] = { "- [x] タスクA completed_at:2026-08-20" } })
			)
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.TODAY], "タスクA")

			local ok = editor_mod.toggle_task_complete(t, config.sections.TODAY)
			assert.is_true(ok)

			local after = io_mod.read_todo_file(todo_path)
			local toggled = task_in(after.sections[config.sections.TODAY], "タスクA")
			assert.equals(" ", toggled.status)
			assert.is_nil(toggled.completed_at)
		end)
	end)

	describe("M.request_move_task_to", function()
		it("完了済みタスクは拒否する(移動しない)", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({ [config.sections.TODAY] = { "- [x] タスクA completed_at:2026-08-20" } })
			)
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.TODAY], "タスクA")

			editor_mod.request_move_task_to(t, config.sections.TODAY, config.sections.NEXT)

			local after = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(task_in(after.sections[config.sections.TODAY], "タスクA"))
			assert.is_nil(task_in(after.sections[config.sections.NEXT], "タスクA"))
		end)

		it("Waitingへの移動はvim.ui.inputでwait:を尋ねる", function()
			io_mod.write_lines(todo_path, standard_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } }))
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.TODAY], "タスクA")

			with_ui_input("田中さん", function()
				editor_mod.request_move_task_to(t, config.sections.TODAY, config.sections.WAITING)
			end)

			local after = io_mod.read_todo_file(todo_path)
			local moved = task_in(after.sections[config.sections.WAITING], "タスクA")
			assert.is_not_nil(moved)
			assert.equals("田中さん", moved.wait)
		end)

		it("Waiting以外への移動はプロンプト無しで即座に行われる", function()
			io_mod.write_lines(todo_path, standard_todo({ [config.sections.NEXT] = { "- [ ] タスクA" } }))
			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.NEXT], "タスクA")

			editor_mod.request_move_task_to(t, config.sections.NEXT, config.sections.SOMEDAY)

			local after = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(task_in(after.sections[config.sections.SOMEDAY], "タスクA"))
		end)
	end)
end)
