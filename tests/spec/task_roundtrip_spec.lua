local task_mod = require("gtodo-md.task")

describe("task.lua parse and serialize roundtrip", function()
	it("フルフィールドのタスクが完全に復元される", function()
		local line =
			"- [ ] (A) テストタスク +project @context due:2025-01-01 created:2024-12-31 wait:2025-01-02 completed_at:2025-01-03"
		local task = task_mod.parse(line)

		assert.are.same("A", task.priority)
		assert.are.same("project", task.project)
		assert.are.same("@context", task.context)
		assert.are.same("2025-01-01", task.due)
		assert.are.same("2025-01-02", task.wait)
		assert.are.same("2024-12-31", task.created)
		assert.are.same("2025-01-03", task.completed_at)
		assert.are.same(" ", task.status)
		assert.are.same("テストタスク", task.content)

		local serialized = task_mod.serialize(task)
		assert.are.same(line, serialized)
	end)

	it("インデントされたタスクが復元される", function()
		local line = "  - [x] 完了したサブタスク"
		local task = task_mod.parse(line)

		assert.are.same("  ", task.indent)
		assert.are.same("x", task.status)
		assert.are.same("完了したサブタスク", task.content)

		local serialized = task_mod.serialize(task)
		assert.are.same(line, serialized)
	end)

	it(
		"タグのような文字列が本文に含まれても破壊されないことの確認 (P0-3 修正完了)",
		function()
			local line = "- [ ] 利益を +5% 向上させる @12:00 due:2025-01-01"
			local task = task_mod.parse(line)

			-- 本文中の "+" や "@" がタグとして誤認されず、行末のメタデータのみが抽出されること
			assert.are.same("利益を +5% 向上させる @12:00", task.content)
			assert.is_nil(task.project)
			assert.is_nil(task.context)
			assert.are.same("2025-01-01", task.due)

			local serialized = task_mod.serialize(task)
			assert.are.same(line, serialized)
		end
	)
end)
