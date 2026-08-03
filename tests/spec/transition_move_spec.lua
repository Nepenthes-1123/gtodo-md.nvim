-- タスクの状態遷移: セクション移動の仕様テスト
--
-- 既存の editor_subsection_spec.lua は #86/#90 の回帰確認(### 見出し配下の
-- タスクを操作できること)に絞られており、セクション移動そのものの仕様
-- (どのセクションへ入るか・同一セクションへの移動・冪等性・wait: の扱い)は
-- カバーされていない。本スペックはそこを埋める。
--
-- 期待値の出典は README_ja.md / doc/gtodo-md.txt の記述と、それだけでは
-- 判断できなかった点についてのメンテナーによる仕様確定である。
-- 実装の現在の挙動ではなく、確定した仕様を期待値として書いている。

local editor_mod = require("gtodo-md.editor")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("状態遷移: セクション移動", function()
	local data_dir, todo_path, inbox_path, buf

	local function task_in(items, content)
		for _, item in ipairs(items or {}) do
			if item.type == "task" and item.task.content == content then
				return item.task
			end
		end
		return nil
	end

	local function count_tasks(items, content)
		local n = 0
		for _, item in ipairs(items or {}) do
			if item.type == "task" and item.task.content == content then
				n = n + 1
			end
		end
		return n
	end

	-- カーソルを指定文字列を含む行へ移動する
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

	-- 4セクションを持つ標準的な todo.md の行を組み立てる。
	-- tasks は { [セクション名] = { 行… } }
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

	-- 標準的な todo.md をバッファとして開く
	local function open_todo(tasks)
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, todo_path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, standard_todo(tasks))
		vim.api.nvim_set_current_buf(buf)
	end

	-- vim.ui.input を差し替えて answer を即座に返す。answer が nil なら中止扱い
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
		inbox_path = data_dir .. "/inbox.md"
	end)

	after_each(function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		buf = nil
		vim.fn.delete(data_dir, "rf")
	end)

	describe("todo.md 内のセクション間移動", function()
		it("Next のタスクを Today へ移動すると Today に現れ Next から消える", function()
			open_todo({ [config.sections.NEXT] = { "- [ ] タスクA" } })
			put_cursor_on("タスクA")

			editor_mod.move_current_task_to(config.sections.TODAY)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(
				task_in(data.sections[config.sections.TODAY], "タスクA"),
				"Today に移動していない"
			)
			assert.is_nil(task_in(data.sections[config.sections.NEXT], "タスクA"), "Next に残っている")
		end)

		it("Today のタスクを Next へ移動できる", function()
			open_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } })
			put_cursor_on("タスクA")

			editor_mod.move_current_task_to(config.sections.NEXT)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(
				task_in(data.sections[config.sections.NEXT], "タスクA"),
				"Next に移動していない"
			)
			assert.is_nil(task_in(data.sections[config.sections.TODAY], "タスクA"), "Today に残っている")
		end)

		it("Today のタスクを Someday へ移動できる", function()
			open_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } })
			put_cursor_on("タスクA")

			editor_mod.move_current_task_to(config.sections.SOMEDAY)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(
				task_in(data.sections[config.sections.SOMEDAY], "タスクA"),
				"Someday に移動していない"
			)
			assert.is_nil(task_in(data.sections[config.sections.TODAY], "タスクA"), "Today に残っている")
		end)

		it("移動してもタスクの内容とタグが保持される", function()
			open_todo({ [config.sections.NEXT] = { "- [ ] (A) タスクA due:2026-08-10 @office +Proj" } })
			put_cursor_on("タスクA")

			editor_mod.move_current_task_to(config.sections.TODAY)

			local data = io_mod.read_todo_file(todo_path)
			local moved = task_in(data.sections[config.sections.TODAY], "タスクA")
			assert.is_not_nil(moved, "Today に移動していない")

			-- 内部表現ではなく、行として書き戻したときにタグが残ることを確認する
			-- (id: は serialize 時に自動発行されるため部分一致で検証する)
			local line = require("gtodo-md.task").serialize(moved)
			assert.is_not_nil(line:find("(A)", 1, true), "優先度が失われている: " .. line)
			assert.is_not_nil(line:find("due:2026-08-10", 1, true), "due が失われている: " .. line)
			assert.is_not_nil(line:find("@office", 1, true), "context が失われている: " .. line)
			assert.is_not_nil(line:find("+Proj", 1, true), "project が失われている: " .. line)
		end)
	end)

	describe("同一セクションへの移動 (no-op)", function()
		it("Today のタスクを Today へ移動しても複製されない", function()
			open_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } })
			put_cursor_on("タスクA")

			editor_mod.move_current_task_to(config.sections.TODAY)

			local data = io_mod.read_todo_file(todo_path)
			assert.equals(
				1,
				count_tasks(data.sections[config.sections.TODAY], "タスクA"),
				"Today で複製されている"
			)
		end)
	end)

	describe("冪等性", function()
		it("同じ移動を2回行ってもタスクが複製されない", function()
			open_todo({ [config.sections.NEXT] = { "- [ ] タスクA" } })

			put_cursor_on("タスクA")
			editor_mod.move_current_task_to(config.sections.TODAY)
			put_cursor_on("タスクA")
			editor_mod.move_current_task_to(config.sections.TODAY)

			local data = io_mod.read_todo_file(todo_path)
			assert.equals(
				1,
				count_tasks(data.sections[config.sections.TODAY], "タスクA"),
				"Today で複製されている"
			)
			assert.equals(0, count_tasks(data.sections[config.sections.NEXT], "タスクA"), "Next に残っている")
		end)
	end)

	describe("inbox.md からの移動", function()
		-- 仕様確定 Q1: inbox.md のタスクに移動操作を行うと todo.md の該当セクションへ入る
		it(
			"inbox.md のタスクを Today へ移動すると todo.md の Today へ入り inbox から消える",
			function()
				io_mod.write_lines(todo_path, standard_todo())

				buf = vim.api.nvim_create_buf(true, false)
				vim.api.nvim_buf_set_name(buf, inbox_path)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Inbox", "", "- [ ] 受信タスク", "" })
				vim.api.nvim_set_current_buf(buf)
				put_cursor_on("受信タスク")

				editor_mod.move_current_task_to(config.sections.TODAY)

				local todo_data = io_mod.read_todo_file(todo_path)
				assert.is_not_nil(
					task_in(todo_data.sections[config.sections.TODAY], "受信タスク"),
					"todo.md の Today へ移動していない"
				)

				local inbox_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local still_there = false
				for _, l in ipairs(inbox_lines) do
					if l:find("受信タスク", 1, true) then
						still_there = true
					end
				end
				assert.is_false(still_there, "inbox.md にタスクが残っている")
			end
		)
	end)

	describe("wait: タグの扱い", function()
		-- 仕様確定 Q15: Waiting へ移動する際に待ち先を対話的に設定する
		it("Waiting へ移動する際に入力した内容が wait: として設定される", function()
			open_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } })
			put_cursor_on("タスクA")

			with_ui_input("田中さん", function()
				editor_mod.move_current_task_to(config.sections.WAITING)
			end)

			local data = io_mod.read_todo_file(todo_path)
			local moved = task_in(data.sections[config.sections.WAITING], "タスクA")
			assert.is_not_nil(moved, "Waiting に移動していない")
			assert.equals("田中さん", moved.wait)
		end)

		it("Waiting へ移動する際に空入力で確定すると wait: は付与されない", function()
			open_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } })
			put_cursor_on("タスクA")

			with_ui_input("", function()
				editor_mod.move_current_task_to(config.sections.WAITING)
			end)

			local data = io_mod.read_todo_file(todo_path)
			local moved = task_in(data.sections[config.sections.WAITING], "タスクA")
			assert.is_not_nil(moved, "Waiting に移動していない")
			assert.is_nil(moved.wait, "wait: が付与されている")
		end)

		-- 仕様確定 Q15(追加): Waiting 以外へ移動すると wait: は削除される
		-- この挙動は README / doc のいずれにも記載がない
		it("Waiting のタスクを Today へ移動すると wait: が削除される", function()
			open_todo({ [config.sections.WAITING] = { "- [ ] タスクA wait:田中さん" } })
			put_cursor_on("タスクA")

			editor_mod.move_current_task_to(config.sections.TODAY)

			local data = io_mod.read_todo_file(todo_path)
			local moved = task_in(data.sections[config.sections.TODAY], "タスクA")
			assert.is_not_nil(moved, "Today に移動していない")
			assert.is_nil(moved.wait, "Waiting 以外へ移動したのに wait: が残っている")
		end)
	end)

	-- 同一セクションへの移動は原則 no-op だが、Waiting だけは例外とする。
	-- wait: を変更する手段がこの経路以外に存在しないため。
	describe("Waiting 内での wait: の更新 (no-op の例外)", function()
		it("既に Waiting にいるタスクの wait: を書き換えられる", function()
			open_todo({ [config.sections.WAITING] = { "- [ ] タスクA wait:田中さん" } })
			put_cursor_on("タスクA")

			with_ui_input("鈴木さん", function()
				editor_mod.move_current_task_to(config.sections.WAITING)
			end)

			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.WAITING], "タスクA")
			assert.is_not_nil(t, "Waiting から消えている")
			assert.equals("鈴木さん", t.wait)
			assert.equals(1, count_tasks(data.sections[config.sections.WAITING], "タスクA"), "複製されている")
		end)

		it("既に Waiting にいるタスクの wait: を空入力で削除できる", function()
			open_todo({ [config.sections.WAITING] = { "- [ ] タスクA wait:田中さん" } })
			put_cursor_on("タスクA")

			with_ui_input("", function()
				editor_mod.move_current_task_to(config.sections.WAITING)
			end)

			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.WAITING], "タスクA")
			assert.is_not_nil(t, "Waiting から消えている")
			assert.is_nil(t.wait, "wait: が削除されていない")
		end)

		it("プロンプトを中止すると wait: は変化しない", function()
			open_todo({ [config.sections.WAITING] = { "- [ ] タスクA wait:田中さん" } })
			put_cursor_on("タスクA")

			with_ui_input(nil, function()
				editor_mod.move_current_task_to(config.sections.WAITING)
			end)

			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.WAITING], "タスクA")
			assert.is_not_nil(t, "Waiting から消えている")
			assert.equals("田中さん", t.wait)
		end)
	end)
end)
