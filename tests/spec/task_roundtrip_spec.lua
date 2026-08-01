local task_mod = require("gtodo-md.task")

-- serialize が末尾に付与する id:XXXXXX タグはランダムに発行されるため、
-- ラウンドトリップの厳密一致比較ではこれを除いた文字列で比較する。
local function strip_id(line)
	return (line:gsub("%s+id:%x+%s*$", ""))
end

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
		assert.are.same(line, strip_id(serialized))
		assert.is_not_nil(serialized:match("%sid:%x+$"), "serializeでIDが付与されていない")
	end)

	it("インデントされたタスクが復元される", function()
		local line = "  - [x] 完了したサブタスク"
		local task = task_mod.parse(line)

		assert.are.same("  ", task.indent)
		assert.are.same("x", task.status)
		assert.are.same("完了したサブタスク", task.content)

		local serialized = task_mod.serialize(task)
		assert.are.same(line, strip_id(serialized))
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
			assert.are.same(line, strip_id(serialized))
		end
	)

	describe("id: タグの自動発行", function()
		it(
			"IDが無いタスクをserializeすると新規に発行され、taskテーブルにも反映される",
			function()
				local task = task_mod.parse("- [ ] 新規タスク")
				assert.is_nil(task.id)

				local serialized = task_mod.serialize(task)
				assert.is_not_nil(task.id, "serialize後、taskテーブルにidが反映されていない")
				assert.are.same("- [ ] 新規タスク id:" .. task.id, serialized)
			end
		)

		it("既にIDがあるタスクをserializeしても上書きされない", function()
			local task = task_mod.parse("- [ ] 既存タスク id:abc123")
			assert.are.same("abc123", task.id)

			local serialized = task_mod.serialize(task)
			assert.are.same("abc123", task.id)
			assert.are.same("- [ ] 既存タスク id:abc123", serialized)
		end)

		it("parseはid:タグを正しく抽出する", function()
			local task = task_mod.parse("- [ ] タスク due:2025-01-01 id:f00ba1")
			assert.are.same("f00ba1", task.id)
			assert.are.same("タスク", task.content)
		end)
	end)

	describe("_generate_id", function()
		it("6桁の16進数文字列を返す", function()
			local id = task_mod._generate_id()
			assert.is_not_nil(id:match("^%x%x%x%x%x%x$"), "id形式が想定と異なる: " .. id)
		end)

		it("連続で呼び出しても重複しにくい(簡易な統計チェック)", function()
			local seen = {}
			local duplicates = 0
			for _ = 1, 500 do
				local id = task_mod._generate_id()
				if seen[id] then
					duplicates = duplicates + 1
				end
				seen[id] = true
			end
			assert.are.same(0, duplicates, "500回中に重複IDが発生した")
		end)
	end)
end)
