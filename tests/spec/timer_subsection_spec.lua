-- #86 の回帰テスト。
-- 旧実装の check_waiting_tasks は todo_data.sections[WAITING] を
-- (get_section_items すら経由せず)直接 ipairs していたため、ネスト構造
-- { items, subsections } 全体を渡すと1件もヒットせず、Waitingタスクの
-- 期日警告が常に0件になっていた。サブセクション配下かどうかに関わらず
-- 再現するが、### 見出し配下でも正しく検知できることを確認する。

local timer_mod = require("gtodo-md.timer")
local io_mod = require("gtodo-md.io")
local config = require("gtodo-md.config")

describe("timer.check_waiting_tasks", function()
	local data_dir, todo_path
	local original_notify, captured

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir, waiting_warning_days = 3 })
		todo_path = data_dir .. "/todo.md"

		captured = {}
		original_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(captured, { msg = msg, level = level })
		end
	end)

	after_each(function()
		vim.notify = original_notify
		vim.fn.delete(data_dir, "rf")
	end)

	it("### 見出し配下のWaitingタスクも期日警告の対象になる", function()
		local today = os.date("%Y-%m-%d")
		io_mod.write_lines(todo_path, {
			"# Todo",
			"",
			"## Waiting",
			"",
			"### 先方待ち",
			"- [ ] 返信待ちタスク due:" .. today .. " wait:相手",
			"",
		})

		timer_mod.check_waiting_tasks()

		assert.equals(1, #captured, "vim.notifyが呼ばれていない: " .. vim.inspect(captured))
		assert.is_true(captured[1].msg:find("返信待ちタスク", 1, true) ~= nil, captured[1].msg)
	end)
end)
