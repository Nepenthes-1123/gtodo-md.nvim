-- タスクの状態遷移: 期日到達による自動昇格の仕様テスト
--
-- 既存の logic_dues_spec.lua は Next / Inbox を中心にカバーしているが、
-- 「どのセクションが昇格元なのか」という仕様の核心は未カバーである。
-- 特に Someday と Waiting の扱いが検証されていない。
--
-- 確定仕様: 昇格元は Inbox / Next / Someday。Waiting は昇格対象外。
--           昇格先は常に Today。境界は due <= 今日(当日を含む)。

local logic_mod = require("gtodo-md.logic")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("状態遷移: 期日到達による自動昇格", function()
	local data_dir, todo_path, inbox_path

	local today = os.date("%Y-%m-%d")
	local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
	local tomorrow = os.date("%Y-%m-%d", os.time() + 86400)

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

	local function setup_config(opts)
		config.setup(vim.tbl_extend("force", {
			data_dir = data_dir,
			due_notification_persist = false,
			due_notification_cooldown = 0,
		}, opts or {}))
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		todo_path = data_dir .. "/todo.md"
		inbox_path = data_dir .. "/inbox.md"
		setup_config()
		io_mod.write_lines(inbox_path, { "# Inbox", "" })
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	describe("Someday からの昇格", function()
		it("Someday の due=今日 のタスクが Today へ昇格する", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.SOMEDAY] = { "- [ ] いつかタスク due:" .. today },
				})
			)

			logic_mod.check_dues(inbox_path, todo_path)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(
				task_in(data.sections[config.sections.TODAY], "いつかタスク"),
				"Today へ昇格していない"
			)
			assert.is_nil(
				task_in(data.sections[config.sections.SOMEDAY], "いつかタスク"),
				"Someday に残っている"
			)
		end)

		it("Someday の due=昨日 のタスクが Today へ昇格する", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.SOMEDAY] = { "- [ ] いつかタスク due:" .. yesterday },
				})
			)

			logic_mod.check_dues(inbox_path, todo_path)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(
				task_in(data.sections[config.sections.TODAY], "いつかタスク"),
				"Today へ昇格していない"
			)
		end)

		it("Someday の due=明日 のタスクは昇格しない", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.SOMEDAY] = { "- [ ] いつかタスク due:" .. tomorrow },
				})
			)

			logic_mod.check_dues(inbox_path, todo_path)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_nil(
				task_in(data.sections[config.sections.TODAY], "いつかタスク"),
				"Today へ昇格してしまっている"
			)
			assert.is_not_nil(
				task_in(data.sections[config.sections.SOMEDAY], "いつかタスク"),
				"Someday から消えている"
			)
		end)
	end)

	describe("Waiting は昇格対象外", function()
		-- 仕様確定 Q4: 昇格元は Inbox / Next / Someday のみ。
		-- Waiting は「他者待ち」を表すセクションであり、期日が来ても
		-- 自動で Today へ動かさない。
		it("Waiting の due=昨日 のタスクは Today へ昇格せず Waiting に留まる", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.WAITING] = {
						"- [ ] 返信待ちタスク due:" .. yesterday .. " wait:田中さん",
					},
				})
			)

			logic_mod.check_dues(inbox_path, todo_path)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_nil(
				task_in(data.sections[config.sections.TODAY], "返信待ちタスク"),
				"Waiting のタスクが Today へ昇格してしまっている"
			)
			assert.is_not_nil(
				task_in(data.sections[config.sections.WAITING], "返信待ちタスク"),
				"Waiting から消えている"
			)
		end)

		it("Waiting の due=今日 のタスクも Waiting に留まる", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.WAITING] = { "- [ ] 返信待ちタスク due:" .. today },
				})
			)

			logic_mod.check_dues(inbox_path, todo_path)

			local data = io_mod.read_todo_file(todo_path)
			assert.is_nil(
				task_in(data.sections[config.sections.TODAY], "返信待ちタスク"),
				"Waiting のタスクが Today へ昇格してしまっている"
			)
		end)
	end)

	describe("auto_move_inbox_to_today の切り替え", function()
		it("false のとき inbox の due=今日 のタスクは Inbox に留まる", function()
			setup_config({ auto_move_inbox_to_today = false })
			io_mod.write_lines(inbox_path, { "# Inbox", "", "- [ ] 受信タスク due:" .. today })
			io_mod.write_lines(todo_path, standard_todo())

			logic_mod.check_dues(inbox_path, todo_path)

			local inbox_data = io_mod.read_todo_file(inbox_path)
			local todo_data = io_mod.read_todo_file(todo_path)
			assert.is_not_nil(task_in(inbox_data.sections["default"], "受信タスク"), "Inbox から消えている")
			assert.is_nil(
				task_in(todo_data.sections[config.sections.TODAY], "受信タスク"),
				"Today へ移動している"
			)
		end)

		it("true のとき inbox の due=昨日 のタスクは Today へ移動する", function()
			setup_config({ auto_move_inbox_to_today = true })
			io_mod.write_lines(inbox_path, { "# Inbox", "", "- [ ] 受信タスク due:" .. yesterday })
			io_mod.write_lines(todo_path, standard_todo())

			logic_mod.check_dues(inbox_path, todo_path)

			local inbox_data = io_mod.read_todo_file(inbox_path)
			local todo_data = io_mod.read_todo_file(todo_path)
			assert.is_nil(task_in(inbox_data.sections["default"], "受信タスク"), "Inbox に残っている")
			assert.is_not_nil(
				task_in(todo_data.sections[config.sections.TODAY], "受信タスク"),
				"Today へ移動していない"
			)
		end)
	end)

	describe("冪等性", function()
		it("2回実行してもタスクが複製されない", function()
			io_mod.write_lines(
				todo_path,
				standard_todo({
					[config.sections.NEXT] = { "- [ ] タスクA due:" .. today },
				})
			)

			logic_mod.check_dues(inbox_path, todo_path)
			logic_mod.check_dues(inbox_path, todo_path)

			local data = io_mod.read_todo_file(todo_path)
			local n = 0
			for _, item in ipairs(data.sections[config.sections.TODAY] or {}) do
				if item.type == "task" and item.task.content == "タスクA" then
					n = n + 1
				end
			end
			assert.equals(1, n, "Today でタスクが複製されている")
		end)
	end)
end)
