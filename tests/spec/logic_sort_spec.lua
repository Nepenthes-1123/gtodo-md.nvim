local logic_mod = require("gtodo-md.logic")
local task_mod = require("gtodo-md.task")

describe("logic.sort_section_tasks general sorting rules", function()
	local function make_items(...)
		local items = {}
		for _, line in ipairs({ ... }) do
			table.insert(items, { type = "task", task = task_mod.parse(line), line = line })
		end
		return items
	end

	it("完了済みタスクは未完了タスクより下になる", function()
		local items = make_items("- [x] 完了タスク due:2020-01-01", "- [ ] 未完了タスク")
		local sorted = logic_mod.sort_section_tasks(items)
		assert.are.same("未完了タスク", sorted[1].task.content)
		assert.are.same("x", sorted[2].task.status)
	end)

	it("dueありタスクはdueなしタスクより上になる", function()
		local items = make_items("- [ ] dueなし", "- [ ] dueあり due:2025-01-01")
		local sorted = logic_mod.sort_section_tasks(items)
		assert.are.same("dueあり", sorted[1].task.content)
		assert.are.same("dueなし", sorted[2].task.content)
	end)

	it("due日付の古い順(昇順)になる", function()
		local items = make_items("- [ ] タスク2 due:2025-02-01", "- [ ] タスク1 due:2025-01-01")
		local sorted = logic_mod.sort_section_tasks(items)
		assert.are.same("タスク1", sorted[1].task.content)
		assert.are.same("タスク2", sorted[2].task.content)
	end)

	it("dueが同じ場合、優先度順になる", function()
		local items = make_items("- [ ] (B) タスクB due:2025-01-01", "- [ ] (A) タスクA due:2025-01-01")
		local sorted = logic_mod.sort_section_tasks(items)
		assert.are.same("タスクA", sorted[1].task.content)
		assert.are.same("タスクB", sorted[2].task.content)
	end)

	it("dueも優先度も同じ場合、元の順序が維持される(stable sort)", function()
		local items = make_items("- [ ] タスクB due:2025-01-01", "- [ ] タスクA due:2025-01-01")
		local sorted = logic_mod.sort_section_tasks(items)
		-- タスクBが先だったなら、ソート後もタスクBが先
		assert.are.same("タスクB", sorted[1].task.content)
		assert.are.same("タスクA", sorted[2].task.content)
	end)

	-- #96: 安定ソートのタイブレークに使う original_index を、以前は呼び出し元の
	-- item オブジェクトへ直接書き込んでいた。これは「ロジック層の関数は入力を
	-- 破壊しない」という方針に反しており、呼び出し元が同じitemを保持し続ける
	-- 限り内部実装の詳細(ソート時の一時的な位置)が漏れ出てしまう。
	it(
		"sort_section_tasksは引数のitemに一切書き込まない(original_indexを汚染しない, #96)",
		function()
			local items = make_items("- [ ] タスクB due:2025-01-01", "- [ ] タスクA due:2025-01-01")
			logic_mod.sort_section_tasks(items)

			for _, item in ipairs(items) do
				assert.is_nil(item.original_index, "sort_section_tasksが引数のitemを直接書き換えている")
			end
		end
	)
end)

-- サブセクション廃止(#86, #90 の根本対応)に伴う一般化テスト。
-- ### 見出しはもはや構造化されず、他のテキスト行と同じ type="text" として
-- 扱われる。sort はこれを「並び替えの境界」として扱い、非タスク行を挟んだ
-- タスクが元のブロックの外へ移動しないことを保証する。
describe("logic.sort_section_tasks 非タスク行を跨いだ並び替えの禁止", function()
	local function item(type_or_line, maybe_line)
		if maybe_line then
			return { type = type_or_line, line = maybe_line }
		end
		return { type = "task", task = task_mod.parse(type_or_line) }
	end

	it("### 見出しを挟んだタスクは見出しブロックの外へ移動しない", function()
		local items = {
			item("text", "### 仕事"),
			item("- [ ] 仕事タスクC due:2025-03-01"),
			item("- [ ] 仕事タスクA due:2025-01-01"),
			item("- [ ] 仕事タスクB due:2025-02-01"),
			item("text", "### プライベート"),
			item("- [ ] 私用タスクB due:2025-02-15"),
			item("- [ ] 私用タスクA due:2025-01-15"),
		}
		local sorted = logic_mod.sort_section_tasks(items)

		assert.are.same("text", sorted[1].type)
		assert.are.same("### 仕事", sorted[1].line)
		assert.are.same("仕事タスクA", sorted[2].task.content)
		assert.are.same("仕事タスクB", sorted[3].task.content)
		assert.are.same("仕事タスクC", sorted[4].task.content)

		assert.are.same("text", sorted[5].type)
		assert.are.same("### プライベート", sorted[5].line)
		assert.are.same("私用タスクA", sorted[6].task.content)
		assert.are.same("私用タスクB", sorted[7].task.content)
	end)

	it("### に限らず、任意のテキスト行が境界として機能する", function()
		local items = {
			item("- [ ] タスクB due:2025-02-01"),
			item("- [ ] タスクA due:2025-01-01"),
			item("text", "メモ: ここから下は別件"),
			item("- [ ] タスクD due:2025-02-01"),
			item("- [ ] タスクC due:2025-01-01"),
		}
		local sorted = logic_mod.sort_section_tasks(items)

		assert.are.same("タスクA", sorted[1].task.content)
		assert.are.same("タスクB", sorted[2].task.content)
		assert.are.same("メモ: ここから下は別件", sorted[3].line)
		assert.are.same("タスクC", sorted[4].task.content)
		assert.are.same("タスクD", sorted[5].task.content)
	end)
end)
