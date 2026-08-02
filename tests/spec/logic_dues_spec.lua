local logic_mod = require("gtodo-md.logic")
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")

describe("logic.check_dues boundary conditions", function()
	local inbox_path = vim.fn.tempname() .. "_inbox.md"
	local todo_path = vim.fn.tempname() .. "_todo.md"

	local today = os.date("%Y-%m-%d")
	local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
	local tomorrow = os.date("%Y-%m-%d", os.time() + 86400)

	before_each(function()
		-- config モック
		config.options = {
			auto_move_inbox_to_today = true,
			due_notification_persist = false,
			due_notification_cooldown = 0,
			sections = {
				TODAY = "Today",
				NEXT = "Next",
				WAITING = "Waiting",
				SOMEDAY = "Someday",
			},
		}
	end)

	after_each(function()
		vim.fn.delete(inbox_path)
		vim.fn.delete(todo_path)
	end)

	it("Nextセクションにあるdue=todayのタスクがTodayに移動する", function()
		local todo_lines = {
			"# Todo",
			"",
			"## Next",
			"",
			"- [ ] タスクA due:" .. today,
			"- [ ] タスクB due:" .. tomorrow,
		}
		io_mod.write_lines(todo_path, todo_lines)
		io_mod.write_lines(inbox_path, { "# Inbox", "" })

		logic_mod.check_dues(inbox_path, todo_path)

		local updated_todo = io_mod.read_todo_file(todo_path)
		local today_items = updated_todo.sections["Today"] or {}
		local next_items = updated_todo.sections["Next"] or {}

		assert.are.same(1, #today_items)
		assert.are.same("タスクA", today_items[1].task.content)
		assert.are.same(1, #next_items)
		assert.are.same("タスクB", next_items[1].task.content)
	end)

	it("Nextセクションにあるdue=yesterdayのタスクがTodayに移動する(期限切れ)", function()
		local todo_lines = {
			"# Todo",
			"",
			"## Next",
			"",
			"- [ ] タスクA due:" .. yesterday,
		}
		io_mod.write_lines(todo_path, todo_lines)
		io_mod.write_lines(inbox_path, { "# Inbox", "" })

		logic_mod.check_dues(inbox_path, todo_path)

		local updated_todo = io_mod.read_todo_file(todo_path)
		local today_items = updated_todo.sections["Today"] or {}

		assert.are.same(1, #today_items)
		assert.are.same("タスクA", today_items[1].task.content)
	end)

	it("Inboxにあるdue=todayのタスクがTodayに移動する", function()
		local inbox_lines = {
			"# Inbox",
			"",
			"- [ ] タスクA due:" .. today,
			"- [ ] タスクB due:" .. tomorrow,
		}
		io_mod.write_lines(inbox_path, inbox_lines)
		io_mod.write_lines(todo_path, { "# Todo", "" })

		logic_mod.check_dues(inbox_path, todo_path)

		local updated_inbox = io_mod.read_todo_file(inbox_path)
		local updated_todo = io_mod.read_todo_file(todo_path)

		local inbox_items = updated_inbox.sections["default"] or {}
		local today_items = updated_todo.sections["Today"] or {}

		assert.are.same(1, #inbox_items)
		assert.are.same("タスクB", inbox_items[1].task.content)

		assert.are.same(1, #today_items)
		assert.are.same("タスクA", today_items[1].task.content)
	end)

	it("完了済みタスク([x])は期限が過ぎていても移動しない", function()
		local todo_lines = {
			"# Todo",
			"",
			"## Next",
			"",
			"- [x] タスクA due:" .. yesterday,
		}
		io_mod.write_lines(todo_path, todo_lines)
		io_mod.write_lines(inbox_path, { "# Inbox", "" })

		logic_mod.check_dues(inbox_path, todo_path)

		local updated_todo = io_mod.read_todo_file(todo_path)
		local today_items = updated_todo.sections["Today"] or {}
		local next_items = updated_todo.sections["Next"] or {}

		assert.are.same(0, #today_items)
		assert.are.same(1, #next_items)
		assert.are.same("タスクA", next_items[1].task.content)
	end)

	-- #87: 未来期日のInboxタスクをWaitingへ自動移動する機能は、宣言だけあって
	-- どこにも値が追加されない未実装のデッドコードだった。「未来期日に変更した
	-- タスクをどこに移動させるかはユーザー自身が操作すべき」との判断で削除し、
	-- 現状維持(Inboxに残り続ける)とした。この現状維持の挙動を回帰確認する。
	it("未来期日のInboxタスクはWaitingへ自動移動されず、Inboxに残り続ける", function()
		local inbox_lines = {
			"# Inbox",
			"",
			"- [ ] 未来のタスク due:" .. tomorrow,
		}
		io_mod.write_lines(inbox_path, inbox_lines)
		io_mod.write_lines(todo_path, { "# Todo", "" })

		logic_mod.check_dues(inbox_path, todo_path)

		local updated_inbox = io_mod.read_todo_file(inbox_path)
		local inbox_items = updated_inbox.sections["default"] or {}
		assert.are.same(1, #inbox_items, "未来期日のタスクがInboxから消えている")
		assert.are.same("未来のタスク", inbox_items[1].task.content)

		local updated_todo = io_mod.read_todo_file(todo_path)
		local waiting_items = updated_todo.sections["Waiting"] or {}
		assert.are.same(0, #waiting_items, "未実装のはずのWaitingへの自動移動が発生している")
	end)

	-- #86/#90 根本原因の回帰テスト: 旧実装は get_section_items 経由で
	-- トップレベルのタスクしか見ておらず、### 見出し配下のdue到達タスクは
	-- 昇格対象として一切スキャンされなかった。
	it("### 見出し配下にあるdue=todayのタスクもTodayに移動する", function()
		local todo_lines = {
			"# Todo",
			"",
			"## Next",
			"",
			"### 仕事",
			"- [ ] 仕事タスクA due:" .. today,
			"- [ ] 仕事タスクB due:" .. tomorrow,
		}
		io_mod.write_lines(todo_path, todo_lines)
		io_mod.write_lines(inbox_path, { "# Inbox", "" })

		logic_mod.check_dues(inbox_path, todo_path)

		local updated_todo = io_mod.read_todo_file(todo_path)
		local today_items = updated_todo.sections["Today"] or {}

		local moved = false
		for _, item in ipairs(today_items) do
			if item.type == "task" and item.task.content == "仕事タスクA" then
				moved = true
			end
		end
		assert.is_true(moved, "### 見出し配下の仕事タスクAがTodayへ移動していない")
	end)
end)
