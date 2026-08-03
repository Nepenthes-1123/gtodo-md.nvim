-- タスクの状態遷移: 完了・done.md への繰り込みの仕様テスト
--
-- 既存の logic_completion_spec.lua は「### 見出し配下で完了したタスクも
-- done.md へ移動する」の1件のみで、完了トグルそのものの仕様
-- (completed_at の付与/削除、冪等性、月見出しの振り分け基準)は未カバー。
--
-- 期待値は確定した仕様であり、実装の現在の挙動ではない。
-- 仕様と実装が食い違う場合、このテストは失敗する。それが検出目的である。

local editor_mod = require("gtodo-md.editor")
local logic_mod = require("gtodo-md.logic")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("状態遷移: 完了と done.md への繰り込み", function()
	local data_dir, todo_path, inbox_path, done_path, buf

	local today = os.date("%Y-%m-%d")

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

	local function open_todo(tasks)
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, todo_path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, standard_todo(tasks))
		vim.api.nvim_set_current_buf(buf)
	end

	local function done_lines()
		if vim.fn.filereadable(done_path) == 0 then
			return {}
		end
		return vim.fn.readfile(done_path)
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
		done_path = data_dir .. "/done.md"
		io_mod.write_lines(inbox_path, { "# Inbox", "" })
	end)

	after_each(function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		buf = nil
		vim.fn.delete(data_dir, "rf")
	end)

	describe("完了トグル", function()
		it("未完了タスクを完了にすると completed_at に今日が設定される", function()
			open_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } })
			put_cursor_on("タスクA")

			editor_mod.toggle_complete()

			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.TODAY], "タスクA")
			assert.is_not_nil(t, "タスクA が見当たらない")
			assert.equals("x", t.status)
			assert.equals(today, t.completed_at)
		end)

		-- 仕様確定 Q2: [x] から [ ] へ戻したとき completed_at は削除される
		it("完了を未完了へ戻すと completed_at が削除される", function()
			open_todo({ [config.sections.TODAY] = { "- [x] タスクA completed_at:2026-08-01" } })
			put_cursor_on("タスクA")

			editor_mod.toggle_complete()

			local data = io_mod.read_todo_file(todo_path)
			local t = task_in(data.sections[config.sections.TODAY], "タスクA")
			assert.is_not_nil(t, "タスクA が見当たらない")
			assert.equals(" ", t.status)
			assert.is_nil(t.completed_at, "completed_at が残っている")
		end)

		it(
			"完了→未完了→完了と往復しても completed_at は1つだけで今日の日付になる",
			function()
				open_todo({ [config.sections.TODAY] = { "- [ ] タスクA" } })

				put_cursor_on("タスクA")
				editor_mod.toggle_complete()
				put_cursor_on("タスクA")
				editor_mod.toggle_complete()
				put_cursor_on("タスクA")
				editor_mod.toggle_complete()

				local data = io_mod.read_todo_file(todo_path)
				local t = task_in(data.sections[config.sections.TODAY], "タスクA")
				assert.is_not_nil(t, "タスクA が見当たらない")
				assert.equals("x", t.status)
				assert.equals(today, t.completed_at)

				local line = require("gtodo-md.task").serialize(t)
				local _, occurrences = line:gsub("completed_at:", "")
				assert.equals(1, occurrences, "completed_at が重複している: " .. line)
			end
		)
	end)

	describe("done.md への繰り込み", function()
		it("完了済みタスクが done.md へ移動し todo.md から消える", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.TODAY] = { "- [x] 完了タスク completed_at:" .. today },
				})
			)

			logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_nil(
				task_in(data.sections[config.sections.TODAY], "完了タスク"),
				"todo.md に残っている"
			)
			assert.equals(1, count_matching(done_lines(), "完了タスク"), "done.md に記録されていない")
		end)

		it("2回実行しても done.md に重複追記されない", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.TODAY] = { "- [x] 完了タスク completed_at:" .. today },
				})
			)

			logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)
			logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)

			assert.equals(1, count_matching(done_lines(), "完了タスク"), "done.md へ重複追記されている")
		end)

		it("未完了タスクは done.md へ移動しない", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.TODAY] = { "- [ ] 未完了タスク" },
				})
			)

			logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(
				task_in(data.sections[config.sections.TODAY], "未完了タスク"),
				"todo.md から消えている"
			)
			assert.equals(0, count_matching(done_lines(), "未完了タスク"), "done.md へ移動している")
		end)

		-- 仕様確定 Q12: done.md の ## YYYY-MM 振り分けは completed_at を基準とする
		it("月見出しは実行日ではなく completed_at の月に振り分けられる", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.TODAY] = { "- [x] 過去に完了したタスク completed_at:2026-06-15" },
				})
			)

			logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)

			local lines = done_lines()
			assert.equals(
				1,
				count_matching(lines, "## 2026-06"),
				"completed_at の月(2026-06)の見出し配下に振り分けられていない: "
					.. table.concat(lines, " / ")
			)
		end)
	end)

	describe("完了済みタスクに対する操作の制限", function()
		-- 仕様確定 Q9: [x] 済みで未移動のタスクをキャンセルすると cancelled.md へ行く
		it("完了済みで未移動のタスクをキャンセルすると cancelled.md へ移動する", function()
			open_todo({ [config.sections.TODAY] = { "- [x] タスクA completed_at:" .. today } })
			put_cursor_on("タスクA")

			editor_mod.cancel_current_task()

			local data = io_mod.read_todo_file(todo_path)
			assert.is_nil(task_in(data.sections[config.sections.TODAY], "タスクA"), "todo.md に残っている")

			local cancelled = vim.fn.readfile(data_dir .. "/cancelled.md")
			assert.equals(1, count_matching(cancelled, "タスクA"), "cancelled.md に記録されていない")
			assert.equals(0, count_matching(done_lines(), "タスクA"), "done.md へ入っている")
		end)

		-- 仕様確定 Q17: [x] 済みで未移動のタスクにセクション移動操作は成立しない
		it("完了済みで未移動のタスクはセクション移動できない", function()
			open_todo({ [config.sections.NEXT] = { "- [x] タスクA completed_at:" .. today } })
			put_cursor_on("タスクA")

			editor_mod.move_current_task_to(config.sections.TODAY)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_nil(
				task_in(data.sections[config.sections.TODAY], "タスクA"),
				"完了済みタスクが Today へ移動してしまっている"
			)
			assert.is_not_nil(
				task_in(data.sections[config.sections.NEXT], "タスクA"),
				"元の Next から消えている"
			)
		end)
	end)
end)
