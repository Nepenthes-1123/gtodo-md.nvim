-- tests/spec/io_parse_spec.lua
-- P0-1 回帰テスト: ### サブ見出しを含む todo.md をソートしても
-- タスクが元の見出しブロック内に留まることを確認する。
--
-- このテストは修正前は FAIL し、修正後は PASS することを期待する。

local io_mod = require("gtodo-md.io")
local logic_mod = require("gtodo-md.logic")

-- ========================================================================
-- ヘルパー
-- ========================================================================

--- section_data の中で指定した ### 見出し配下のタスク一覧を返す。
--- ネスト実装: subsections[i].name == name の items を集める。
--- フラット実装: type="text" の ### 行の直後〜次の ### までの task を集める。
local function tasks_under_subsection(section_data, subsection_name)
	local results = {}

	-- ネスト構造（修正後）
	if type(section_data) == "table" and section_data.items ~= nil then
		if section_data.subsections then
			for _, sub in ipairs(section_data.subsections) do
				if sub.name == subsection_name then
					for _, item in ipairs(sub.items) do
						if item.type == "task" then
							table.insert(results, item.task)
						end
					end
				end
			end
		end
		return results
	end

	-- フラット構造（現行）: ### 行の直後〜次の ### or 末尾
	local in_target = false
	for _, item in ipairs(section_data) do
		if item.type == "text" then
			local h3 = item.line:match("^###%s+(.-)%s*$")
			if h3 then
				in_target = (h3 == subsection_name)
			end
		elseif item.type == "task" and in_target then
			table.insert(results, item.task)
		end
	end
	return results
end

--- section_data から items を取り出す（フラット配列 or ネスト構造どちらでも）
local function get_items(sec)
	if type(sec) == "table" and sec.items ~= nil then
		return sec.items
	end
	return sec
end

-- ========================================================================
-- テストスイート
-- ========================================================================

describe("io.parse_markdown", function()
	-- ------------------------------------------------------------------
	-- ラウンドトリップテスト (P3 基礎)
	-- ------------------------------------------------------------------
	describe("ラウンドトリップ: parse のサニティチェック", function()
		it("### のない単純な todo.md が正しくパースされる", function()
			local lines = {
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] タスクA due:2025-01-01",
				"- [ ] タスクB",
				"- [x] タスクC（完了）",
				"",
				"## Next",
				"",
				"- [ ] タスクD",
			}
			local data = io_mod.parse_markdown(lines)

			local today_items = get_items(data.sections["Today"])
			local next_items = get_items(data.sections["Next"])

			assert.is_not_nil(today_items)
			assert.is_not_nil(next_items)
			assert.equals(3, #today_items)
			assert.equals(1, #next_items)
			assert.equals("Today", data.section_order[1])
			assert.equals("Next", data.section_order[2])
		end)

		it("### 見出しを含む todo.md のパースで ### 行が何らかの形で記録される", function()
			local lines = {
				"# Todo",
				"",
				"## Today",
				"",
				"### 仕事",
				"- [ ] 仕事タスクA",
				"- [ ] 仕事タスクB",
				"",
				"### プライベート",
				"- [ ] 私用タスクA",
			}
			local data = io_mod.parse_markdown(lines)
			local today = data.sections["Today"]
			assert.is_not_nil(today)

			-- ネスト構造の場合: subsections に記録される
			if type(today) == "table" and today.items ~= nil then
				assert.is_not_nil(today.subsections, "ネスト構造では subsections が存在するべき")
				assert.equals(2, #today.subsections)
				assert.equals("仕事", today.subsections[1].name)
				assert.equals("プライベート", today.subsections[2].name)
			else
				-- フラット構造: type="text" に ### 行が含まれているはず
				local found_h3 = false
				for _, item in ipairs(today) do
					if item.type == "text" and item.line:match("^###") then
						found_h3 = true
						break
					end
				end
				assert.is_true(found_h3, "フラット実装では ### 行が type=text として保存されるはず")
			end
		end)
	end)

	-- ------------------------------------------------------------------
	-- P0-1 回帰テスト: ソート後にタスクが元の見出しブロック内に留まる
	-- ------------------------------------------------------------------
	describe("P0-1: sort_section_tasks でサブ見出し内タスクが崩壊しない", function()
		--- テスト用データ: 「仕事」「プライベート」の 2 サブセクションを持つ ## Today
		--- ソート前は意図的に due 降順で並べておき、ソート後に昇順になることも検証する
		local function make_data_with_subsections()
			local lines = {
				"# Todo",
				"",
				"## Today",
				"",
				"### 仕事",
				"- [ ] 仕事タスクC due:2025-03-01",
				"- [ ] 仕事タスクA due:2025-01-01",
				"- [ ] 仕事タスクB due:2025-02-01",
				"",
				"### プライベート",
				"- [ ] 私用タスクB due:2025-02-15",
				"- [ ] 私用タスクA due:2025-01-15",
			}
			return io_mod.parse_markdown(lines)
		end

		-- -----------------------------------------------------------------------
		-- テスト 1: 「仕事」ブロック内のタスク件数がソート後も 3 件
		-- -----------------------------------------------------------------------
		-- 【不具合の再現】
		-- フラット実装の sort_section_tasks は以下の挙動をする:
		--   items 配列  = [text:###仕事, task:C, task:A, task:B, text:###プライベ, task:B2, task:A2]
		--   task のみを抽出 → [C, A, B, B2, A2]（インデックス 2,3,4,6,7）
		--   due 昇順ソート → [A, A2, B, B2, C]
		--   元インデックス位置に詰め直す → idx2=A, idx3=A2, idx4=B, idx6=B2, idx7=C
		--   結果: [text:###仕事, A, A2, B, text:###プライベ, B2, C]
		--         → 「仕事」配下に A, A2, B が入り、「プライベ」配下に B2, C が入る ← バグ
		-- 修正後: 「仕事」配下に A, B, C、「プライベート」配下に A2, B2 が入る
		-- -----------------------------------------------------------------------
		it("ソート後も「仕事」配下に 3 件のタスクが残る", function()
			local data = make_data_with_subsections()
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local shigoto_tasks = tasks_under_subsection(sorted, "仕事")
			assert.equals(
				3,
				#shigoto_tasks,
				"「仕事」配下のタスクが 3 件のはずが "
					.. #shigoto_tasks
					.. " 件（サブセクション崩壊）"
			)
		end)

		-- テスト 2: 「プライベート」ブロック内のタスク件数がソート後も 2 件
		it("ソート後も「プライベート」配下に 2 件のタスクが残る", function()
			local data = make_data_with_subsections()
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local private_tasks = tasks_under_subsection(sorted, "プライベート")
			assert.equals(
				2,
				#private_tasks,
				"「プライベート」配下のタスクが 2 件のはずが "
					.. #private_tasks
					.. " 件（サブセクション崩壊）"
			)
		end)

		-- テスト 3: 「仕事」ブロック内では due 昇順にソートされる
		it("「仕事」ブロック内では due 昇順にソートされる", function()
			local data = make_data_with_subsections()
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local shigoto_tasks = tasks_under_subsection(sorted, "仕事")
			if #shigoto_tasks >= 3 then
				-- due フィールドで比較（task.due が抽出されているため content には due: が含まれない）
				assert.equals("2025-01-01", shigoto_tasks[1].due, "仕事ブロック1番目の due が最小のはず")
				assert.equals("2025-02-01", shigoto_tasks[2].due, "仕事ブロック2番目の due が中間のはず")
				assert.equals("2025-03-01", shigoto_tasks[3].due, "仕事ブロック3番目の due が最大のはず")
			end
		end)

		-- テスト 4: 「プライベート」ブロック内では due 昇順にソートされる
		it("「プライベート」ブロック内では due 昇順にソートされる", function()
			local data = make_data_with_subsections()
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local private_tasks = tasks_under_subsection(sorted, "プライベート")
			if #private_tasks >= 2 then
				assert.equals(
					"2025-01-15",
					private_tasks[1].due,
					"プライベートブロック1番目の due が最小のはず"
				)
				assert.equals(
					"2025-02-15",
					private_tasks[2].due,
					"プライベートブロック2番目の due が最大のはず"
				)
			end
		end)

		-- テスト 5: サブセクションの並び順がソートで変わらない
		it(
			"サブセクションの並び順がソート後も「仕事」→「プライベート」のまま",
			function()
				local data = make_data_with_subsections()
				local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

				-- ネスト構造の場合: subsections の順序を直接確認
				if type(sorted) == "table" and sorted.subsections then
					assert.equals("仕事", sorted.subsections[1].name, "「仕事」が先に現れるべき")
					assert.equals(
						"プライベート",
						sorted.subsections[2].name,
						"「プライベート」が後に現れるべき"
					)
				else
					-- フラット構造: ### 行の登場順を確認する
					local first_h3 = ""
					local second_h3 = ""
					for _, item in ipairs(sorted) do
						if item.type == "text" and item.line:match("^###") then
							local h3_name = item.line:match("^###%s+(.-)%s*$")
							if not first_h3 then
								first_h3 = h3_name
							elseif not second_h3 then
								second_h3 = h3_name
								break
							end
						end
					end
					assert.equals("仕事", first_h3, "「仕事」が先に現れるべき")
					assert.equals("プライベート", second_h3, "「プライベート」が後に現れるべき")
				end
			end
		)

		-- テスト 6: ### なしのトップレベルタスクと ### ブロックが混在する場合
		it("トップレベルタスクと ### ブロック混在時も「仕事」配下は 2 件", function()
			local lines = {
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] トップレベルタスクB due:2025-02-01",
				"- [ ] トップレベルタスクA due:2025-01-01",
				"",
				"### 仕事",
				"- [ ] 仕事タスクB due:2025-02-01",
				"- [ ] 仕事タスクA due:2025-01-01",
			}
			local data = io_mod.parse_markdown(lines)
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local shigoto_tasks = tasks_under_subsection(sorted, "仕事")
			assert.equals(
				2,
				#shigoto_tasks,
				"「仕事」配下は 2 件のはずが " .. #shigoto_tasks .. " 件（サブセクション崩壊）"
			)
		end)
	end)
end)
