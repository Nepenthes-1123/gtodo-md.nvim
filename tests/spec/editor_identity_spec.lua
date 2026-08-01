-- P1-4 回帰テスト: タスク同定キーの非一意性による誤操作
-- content + created が同一のタスクが複数あるとき、カーソル位置のタスクを
-- 正しく同定できることを確認する。
--
-- このテストは修正前に FAIL する（editor_mod._find_task_idx が存在しない）。
-- 修正後に PASS する。

local task_mod = require("gtodo-md.task")
local editor_mod = require("gtodo-md.editor")

describe("editor._find_task_idx (P1-4: 重複タスクの正しい同定)", function()
	-- ヘルパー: タスク行をパースして item 形式に変換
	local function make_item(line)
		return { type = "task", task = task_mod.parse(line) }
	end

	-- ----------------------------------------------------------------
	-- 基本ケース
	-- ----------------------------------------------------------------
	describe("基本ケース", function()
		it("重複なしの場合、content+created で正常に見つかる", function()
			local items = {
				make_item("- [ ] Task A due:2025-01-10 created:2025-01-01"),
				make_item("- [ ] Task B due:2025-01-20 created:2025-01-01"),
			}
			local cursor_task = task_mod.parse("- [ ] Task B due:2025-01-20 created:2025-01-01")
			local idx = editor_mod._find_task_idx(items, cursor_task)
			assert.equals(2, idx)
		end)

		it("タスクが見つからない場合は nil を返す", function()
			local items = {
				make_item("- [ ] Task A due:2025-01-10 created:2025-01-01"),
			}
			local cursor_task = task_mod.parse("- [ ] Task Z due:2025-01-10 created:2025-01-01")
			local idx = editor_mod._find_task_idx(items, cursor_task)
			assert.is_nil(idx)
		end)
	end)

	-- ----------------------------------------------------------------
	-- P1-4 本体: content + created が同一のタスクが複数ある場合
	-- ----------------------------------------------------------------
	describe("P1-4: content + created が同一のタスクが 2 件ある場合", function()
		-- テストデータ:
		--   1件目: due:2025-01-10 (行テキストが異なる)
		--   2件目: due:2025-01-20 (カーソルはここ)
		-- content と created は両者とも同じ

		local line1 = "- [ ] Task A due:2025-01-10 created:2025-01-01"
		local line2 = "- [ ] Task A due:2025-01-20 created:2025-01-01"

		it("カーソルが 1 件目にあるとき、1 件目を返す", function()
			local items = { make_item(line1), make_item(line2) }
			local cursor_task = task_mod.parse(line1)
			local idx = editor_mod._find_task_idx(items, cursor_task)
			assert.equals(1, idx)
		end)

		it("カーソルが 2 件目にあるとき、2 件目を返す（P1-4 バグ検知）", function()
			local items = { make_item(line1), make_item(line2) }
			-- カーソル行テキストは line2 (2件目)
			local cursor_task = task_mod.parse(line2)
			local idx = editor_mod._find_task_idx(items, cursor_task)
			-- 修正前: content+created のみでは必ず 1 が返る → FAIL
			-- 修正後: original_line 一致で 2 が返る → PASS
			assert.equals(2, idx)
		end)

		it(
			"ファイル書き戻し後(serialize 済み)のラウンドトリップでも正しく同定できる",
			function()
				-- serialize → parse で original_line が変化する場合のフォールバック確認
				-- serialize 後は due が content 直後に来る形式になる
				local task_obj = task_mod.parse(line2)
				local serialized_line = task_mod.serialize(task_obj)
				-- serialized_line を使ってアイテムを作成 (ファイル書き戻し後の状態を模倣)
				local items_after_write = {
					make_item(task_mod.serialize(task_mod.parse(line1))),
					make_item(serialized_line),
				}
				local cursor_task_after_write = task_mod.parse(serialized_line)
				local idx = editor_mod._find_task_idx(items_after_write, cursor_task_after_write)
				assert.equals(2, idx)
			end
		)
	end)

	-- ----------------------------------------------------------------
	-- #82: IDによる最優先の同定
	-- ----------------------------------------------------------------
	describe("#82: IDによる最優先の同定", function()
		it("idが一致すれば、original_lineが一致しなくても正しく同定できる", function()
			local items = {
				make_item("- [ ] Task A due:2025-01-10 id:aaa111"),
				make_item("- [ ] Task A due:2025-01-20 id:bbb222"),
			}
			-- 何らかの理由でoriginal_lineが変化しているが、idは一致する
			local cursor_task = {
				id = "bbb222",
				content = "Task A",
				due = "2025-01-20",
				status = " ",
				original_line = "- [ ] Task A due:2025-01-20 id:bbb222 (改変された行)",
			}
			local idx = editor_mod._find_task_idx(items, cursor_task)
			assert.equals(2, idx)
		end)

		it(
			"content+createdが同一の重複タスクでも、idが異なれば正しく区別できる(#82解決)",
			function()
				local line1 = "- [ ] Task A due:2025-01-10 created:2025-01-01 id:aaa111"
				local line2 = "- [ ] Task A due:2025-01-20 created:2025-01-01 id:bbb222"
				local items = { make_item(line1), make_item(line2) }

				local cursor_task = task_mod.parse(line2)
				-- original_lineをわざと不一致にして、Primary(id)だけが頼りになる状況を作る
				cursor_task.original_line = "改変されたテキスト"

				local idx = editor_mod._find_task_idx(items, cursor_task)
				assert.equals(2, idx)
			end
		)

		it("idが一致しなければPrimaryは発動せずSecondary/Fallbackに進む", function()
			local items = {
				make_item("- [ ] Task A due:2025-01-10 id:aaa111"),
			}
			local cursor_task = task_mod.parse("- [ ] Task A due:2025-01-10 id:zzz999")
			local idx = editor_mod._find_task_idx(items, cursor_task)
			assert.equals(1, idx)
		end)
	end)

	-- ----------------------------------------------------------------
	-- フォールバック: original_line が一致しない場合
	-- ----------------------------------------------------------------
	describe("フォールバック動作", function()
		it("original_line が nil の場合は content+created で照合する", function()
			local items = {
				make_item("- [ ] Task A due:2025-01-10 created:2025-01-01"),
				make_item("- [ ] Task A due:2025-01-20 created:2025-01-01"),
			}
			-- original_line を意図的に nil にした cursor_task
			local cursor_task = {
				content = "Task A",
				created = "2025-01-01",
				due = "2025-01-10",
				status = " ",
				original_line = nil,
			}
			-- フォールバックで content+created 照合 → 1件目が返る
			local idx = editor_mod._find_task_idx(items, cursor_task)
			assert.equals(1, idx)
		end)
	end)
end)
