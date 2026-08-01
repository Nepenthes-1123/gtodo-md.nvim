-- tests/spec/io_parse_spec.lua
-- P0-1 / #86 / #90 回帰テスト: ### サブ見出しを含む todo.md をソートしても
-- タスクが元の見出しブロック内に留まることを確認する。
--
-- サブセクションは構造化されたデータではなく、他のテキスト行と同じ
-- type="text" のフラットなアイテムとして扱われる。sort はこれを
-- 並び替えの境界として扱うことで、タスクが元のブロックの外へ
-- 移動しないことを保証している。

local io_mod = require("gtodo-md.io")
local logic_mod = require("gtodo-md.logic")

-- ========================================================================
-- ヘルパー
-- ========================================================================

--- section_data (フラットな items 配列) の中で指定した ### 見出し配下の
--- タスク一覧を返す。### 行の直後〜次の ### or 末尾までの task を集める。
local function tasks_under_subsection(section_data, subsection_name)
	local results = {}
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

			local today_items = data.sections["Today"]
			local next_items = data.sections["Next"]

			assert.is_not_nil(today_items)
			assert.is_not_nil(next_items)
			assert.equals(3, #today_items)
			assert.equals(1, #next_items)
			assert.equals("Today", data.section_order[1])
			assert.equals("Next", data.section_order[2])
		end)

		it("### 見出しを含む todo.md のパースで ### 行が type=text として保持される", function()
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

			local found_h3 = false
			for _, item in ipairs(today) do
				if item.type == "text" and item.line:match("^###") then
					found_h3 = true
					break
				end
			end
			assert.is_true(found_h3, "### 行が type=text として保存されるはず")
		end)
	end)

	-- ------------------------------------------------------------------
	-- P0-1 / #86 / #90 回帰テスト: ソート後にタスクが元の見出しブロック内に留まる
	-- ------------------------------------------------------------------
	describe("P0-1: sort_section_tasks でサブ見出し内タスクが崩壊しない", function()
		--- テスト用データ: 「仕事」「プライベート」の 2 サブ見出しを持つ ## Today
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

		it("「仕事」ブロック内では due 昇順にソートされる", function()
			local data = make_data_with_subsections()
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local shigoto_tasks = tasks_under_subsection(sorted, "仕事")
			assert.equals("2025-01-01", shigoto_tasks[1].due, "仕事ブロック1番目の due が最小のはず")
			assert.equals("2025-02-01", shigoto_tasks[2].due, "仕事ブロック2番目の due が中間のはず")
			assert.equals("2025-03-01", shigoto_tasks[3].due, "仕事ブロック3番目の due が最大のはず")
		end)

		it("「プライベート」ブロック内では due 昇順にソートされる", function()
			local data = make_data_with_subsections()
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local private_tasks = tasks_under_subsection(sorted, "プライベート")
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
		end)

		it("サブ見出しの並び順がソート後も「仕事」→「プライベート」のまま", function()
			local data = make_data_with_subsections()
			local sorted = logic_mod.sort_section_tasks(data.sections["Today"])

			local first_h3, second_h3
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
		end)

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
