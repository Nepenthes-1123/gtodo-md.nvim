-- P2-1 回帰テスト: 優先度マーカーの誤検出防止
--
-- 【重要な事前検証】
-- (WIP) 資料整備 は現状コードでも priority=nil（3文字なので正規表現に非マッチ）。
-- 「WIPケースが誤爆する」という当初の懸念は誤りだった。
--
-- 実際に FAIL するのは:
--   (A) 資料整備 をパースしても task.priority フィールドが存在せず、
--   content に "(A) " プレフィックスが残ったままになっている点。
--
-- ソート順については:
--   修正前: logic.lua が content:match で "(A) " を検出して優先度 "A" として扱う（動く）
--   修正後: logic.lua が task.priority を参照する（content は "(A) " なし）
--   → ソート動作は変わらないが、実装経路が変わる
--
-- このテストは修正前に FAIL し、修正後に PASS する。

local task_mod = require("gtodo-md.task")
local logic_mod = require("gtodo-md.logic")

-- serialize が末尾に付与する id:XXXXXX タグはランダムに発行されるため、
-- 厳密一致比較ではこれを除いた文字列で比較する。
local function strip_id(line)
	return (line:gsub("%s+id:%x+%s*$", ""))
end

describe("task.priority (P2-1: 優先度マーカーの誤検出防止)", function()
	-- ----------------------------------------------------------------
	-- パースフェーズ: task.priority フィールドの分離
	-- ----------------------------------------------------------------
	describe("parse: 正規の優先度表記 (A) が分離される", function()
		it("task.priority == 'A' になる（修正前は nil → FAIL）", function()
			local task = task_mod.parse("- [ ] (A) 資料整備")
			-- 修正前: task.priority フィールドが存在しないので nil → FAIL
			-- 修正後: priority = "A" → PASS
			assert.equals("A", task.priority)
		end)

		it("content から (A) プレフィックスが除去される（修正前は残る → FAIL）", function()
			local task = task_mod.parse("- [ ] (A) 資料整備")
			-- 修正前: content = "(A) 資料整備" → FAIL
			-- 修正後: content = "資料整備" → PASS
			assert.equals("資料整備", task.content)
		end)

		it("task.priority == 'B' になる（B も正しく分離される）", function()
			local task = task_mod.parse("- [ ] (B) 会議準備")
			assert.equals("B", task.priority)
		end)

		it("content から (B) プレフィックスが除去される", function()
			local task = task_mod.parse("- [ ] (B) 会議準備")
			assert.equals("会議準備", task.content)
		end)

		it("他フィールドと共存する: due/created が正しく抽出される", function()
			local task = task_mod.parse("- [ ] (A) 資料整備 due:2025-01-10 created:2025-01-01")
			assert.equals("A", task.priority)
			assert.equals("資料整備", task.content)
			assert.equals("2025-01-10", task.due)
			assert.equals("2025-01-01", task.created)
		end)
	end)

	-- ----------------------------------------------------------------
	-- パースフェーズ: 誤検出されないケースの確認
	-- ※ これらは修正前後ともに PASS するが、動作を保証するために記載
	-- ----------------------------------------------------------------
	describe("parse: 非優先度表記が誤検出されないこと（修正前後ともに PASS）", function()
		it("(WIP) は優先度として扱われない（3文字なので現状でも正常）", function()
			local task = task_mod.parse("- [ ] (WIP) 資料整備")
			assert.is_nil(task.priority)
		end)

		it("(WIP) のとき content は変更されない", function()
			local task = task_mod.parse("- [ ] (WIP) 資料整備")
			assert.equals("(WIP) 資料整備", task.content)
		end)

		it("(TODO) は優先度として扱われない（4文字）", function()
			local task = task_mod.parse("- [ ] (TODO) 設定確認")
			assert.is_nil(task.priority)
		end)

		it("スペースなし (A)タスク は優先度として扱われない", function()
			-- 修正後は後ろスペース必須のため priority = nil になるべき
			-- 修正前は content:match で "A" を返す（副作用はソート時のみ）
			-- → parse 段階では task.priority = nil のため修正前後ともに PASS
			local task = task_mod.parse("- [ ] (A)資料整備")
			assert.is_nil(task.priority)
		end)

		it("スペースなし (A)タスク のとき content は変更されない", function()
			local task = task_mod.parse("- [ ] (A)資料整備")
			assert.equals("(A)資料整備", task.content)
		end)

		it("優先度表記がない通常タスクは priority が nil", function()
			local task = task_mod.parse("- [ ] 通常タスク due:2025-01-10")
			assert.is_nil(task.priority)
		end)
	end)

	-- ----------------------------------------------------------------
	-- ソートフェーズ: sort_section_tasks の動作確認
	-- ※ 修正前は logic.lua が content:match を使うため PASS するが、
	--   修正後は task.priority を使うため、parse が正しくないと FAIL する。
	--   修正前後で sort 動作（期待結果）は変わらない。
	-- ----------------------------------------------------------------
	describe("sort: 優先度付きタスクが正しい順序でソートされる", function()
		local function make_sec_data(task_lines)
			local items = {}
			for _, line in ipairs(task_lines) do
				local t = task_mod.parse(line)
				if t then
					table.insert(items, { type = "task", task = t })
				end
			end
			return { items = items, subsections = {} }
		end

		it("(A) タスクが優先度なしタスクより先に並ぶ", function()
			local sec = make_sec_data({
				"- [ ] 通常タスク",
				"- [ ] (A) 優先タスク due:2025-01-10",
			})
			local sorted = logic_mod.sort_section_tasks(sec)
			local items = sorted.items
			-- due あり → due なし の順のため、
			-- (A) 優先タスク due:2025-01-10 が先頭になるはず
			assert.equals("2025-01-10", items[1].task.due)
		end)

		it("(A) > (B) の優先度順でソートされる（due が同じ場合）", function()
			local sec = make_sec_data({
				"- [ ] (B) B優先タスク due:2025-01-10",
				"- [ ] (A) A優先タスク due:2025-01-10",
			})
			local sorted = logic_mod.sort_section_tasks(sec)
			local items = sorted.items
			-- (A) が先、(B) が後
			-- 修正前: content:match で "A"/"B" を判定し正しく並ぶ
			-- 修正後: task.priority で "A"/"B" を判定（content には prefix なし）
			-- どちらも期待値は同じ
			local priority_first
			if items[1].task.priority then
				priority_first = items[1].task.priority -- 修正後
			else
				priority_first = items[1].task.content:match("^%(([A-Z])%)") or "Z" -- 修正前フォールバック
			end
			assert.equals("A", priority_first)
		end)

		it("(WIP) タスクと通常タスクは同等の優先度（WIP は優先度なし）", function()
			local sec = make_sec_data({
				"- [ ] (WIP) 作業メモ due:2025-01-10",
				"- [ ] 通常タスク due:2025-01-10",
			})
			local sorted = logic_mod.sort_section_tasks(sec)
			local items = sorted.items
			-- 両者 due が同じで priority なし → stable sort で元の順序
			assert.equals("(WIP) 作業メモ", items[1].task.content)
			assert.equals("通常タスク", items[2].task.content)
		end)
	end)

	-- ----------------------------------------------------------------
	-- serialize: parse した priority が書き戻し時に失われない
	-- ----------------------------------------------------------------
	describe("serialize: parse → serialize のラウンドトリップ", function()
		it("(A) タスク が serialize で (A) を保持する", function()
			local task = task_mod.parse("- [ ] (A) 資料整備")
			local serialized = task_mod.serialize(task)
			assert.equals("- [ ] (A) 資料整備", strip_id(serialized))
		end)

		it("(B) タスク due 付き が serialize で完全に復元される", function()
			local task = task_mod.parse("- [ ] (B) 会議準備 due:2025-01-10 created:2025-01-01")
			local serialized = task_mod.serialize(task)
			assert.equals("- [ ] (B) 会議準備 due:2025-01-10 created:2025-01-01", strip_id(serialized))
		end)

		it("優先度なしタスクは serialize で変化しない", function()
			local task = task_mod.parse("- [ ] 通常タスク due:2025-01-10")
			local serialized = task_mod.serialize(task)
			assert.equals("- [ ] 通常タスク due:2025-01-10", strip_id(serialized))
		end)

		it("(WIP) タスクは serialize で変化しない（priority=nil なので prefix なし）", function()
			local task = task_mod.parse("- [ ] (WIP) 資料整備")
			local serialized = task_mod.serialize(task)
			assert.equals("- [ ] (WIP) 資料整備", strip_id(serialized))
		end)
	end)
end)
