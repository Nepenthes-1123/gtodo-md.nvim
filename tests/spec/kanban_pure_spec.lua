-- ui/kanban.lua から切り出した純関数の単体テスト。
-- バッファやウィンドウに触れないため、open_kanban() 全体を起動せずに検証できる。

local kanban = require("gtodo-md.ui.kanban")
local task_mod = require("gtodo-md.task")

-- 基準日は固定にして日数差の期待値を安定させる
local TODAY_STR = "2026-08-24"
local TODAY_TIME = require("gtodo-md.utils").date_to_time(TODAY_STR)

local SECTIONS = { SOMEDAY = "Someday", NEXT = "Next", TODAY = "Today", WAITING = "Waiting" }

local function task(line)
	local t = task_mod.parse(line)
	assert.is_not_nil(t, "テスト用のタスク行がパースできない: " .. line)
	return t
end

describe("ui.kanban._truncate_to_width / _pad_to_width", function()
	it("表示幅内に収まる文字列はそのまま返す", function()
		assert.are.same("hello", kanban._truncate_to_width("hello", 10))
	end)

	it("表示幅を超える文字列は省略記号付きで切り詰める", function()
		local result = kanban._truncate_to_width("0123456789", 5)
		assert.are.same("…", result:sub(-3)) -- "…" はUTF-8で3バイト
		assert.is_true(vim.fn.strdisplaywidth(result) <= 5)
	end)

	it("全角文字混じりでも表示幅を超えないよう切り詰める", function()
		local result = kanban._truncate_to_width("あいうえおかきくけこ", 6)
		assert.is_true(vim.fn.strdisplaywidth(result) <= 6)
	end)

	it("_pad_to_width は表示幅ちょうどになるよう空白を埋める", function()
		local padded = kanban._pad_to_width("ab", 5)
		assert.are.same(5, vim.fn.strdisplaywidth(padded))
		assert.are.same("ab   ", padded)
	end)

	it("既に幅以上ある場合は _pad_to_width は変更しない", function()
		assert.are.same("abcdef", kanban._pad_to_width("abcdef", 4))
	end)
end)

describe("ui.kanban._card_body_lines", function()
	it("1行目は本文からなる", function()
		local lines = kanban._card_body_lines(task("- [ ] Buy milk"), 30, TODAY_TIME)
		assert.is_truthy(lines[1]:find("Buy milk", 1, true))
	end)

	it(
		"[ ]/[x] のチェックボックス表記は状態に関わらず表示しない(完了状態は列自体で表現するため)",
		function()
			local incomplete_lines = kanban._card_body_lines(task("- [ ] Buy milk"), 30, TODAY_TIME)
			assert.is_nil(incomplete_lines[1]:find("[ ]", 1, true))

			local done_lines = kanban._card_body_lines(task("- [x] Done task completed_at:2026-08-20"), 30, TODAY_TIME)
			assert.is_nil(done_lines[1]:find("[x]", 1, true))
			assert.is_truthy(done_lines[1]:find("Done task", 1, true))
		end
	)

	it("優先度がある場合は1行目に含め、ハイライトスパンを返す", function()
		local lines, spans = kanban._card_body_lines(task("- [ ] (A) Important task"), 30, TODAY_TIME)
		assert.is_truthy(lines[1]:find("(A)", 1, true))
		assert.are.same(1, #spans)
		assert.are.same("GTodoPriorityA", spans[1].hl_group)
		assert.are.same(1, spans[1].line)
	end)

	it("タグが無ければ本文行だけを返す", function()
		local lines = kanban._card_body_lines(task("- [ ] Plain task"), 30, TODAY_TIME)
		assert.are.same(1, #lines)
	end)

	it("@context / +project / due: / wait: を2行目以降に表示する", function()
		local lines = kanban._card_body_lines(task("- [ ] Task +work @office due:2026-08-24 wait:bob"), 60, TODAY_TIME)
		assert.are.same(2, #lines)
		assert.is_truthy(lines[2]:find("+work", 1, true))
		assert.is_truthy(lines[2]:find("@office", 1, true))
		assert.is_truthy(lines[2]:find("due:2026-08-24", 1, true))
		assert.is_truthy(lines[2]:find("wait:bob", 1, true))
	end)

	it("due日付は今日/明日/N日超過を付記する", function()
		local today_lines = kanban._card_body_lines(task("- [ ] A due:2026-08-24"), 60, TODAY_TIME)
		assert.is_truthy(today_lines[2]:find("(今日)", 1, true))

		local tomorrow_lines = kanban._card_body_lines(task("- [ ] A due:2026-08-25"), 60, TODAY_TIME)
		assert.is_truthy(tomorrow_lines[2]:find("(明日)", 1, true))

		local overdue_lines = kanban._card_body_lines(task("- [ ] A due:2026-08-20"), 60, TODAY_TIME)
		assert.is_truthy(overdue_lines[2]:find("超過", 1, true))
	end)

	it("id等の内部タグは表示しない", function()
		local lines = kanban._card_body_lines(task("- [ ] Task created:2026-08-01 id:abc123"), 60, TODAY_TIME)
		assert.are.same(1, #lines)
	end)

	it("幅に収まらないタグは複数行へ折り返す", function()
		local lines =
			kanban._card_body_lines(task("- [ ] Task +aaaaaaaaaa @bbbbbbbbbb wait:cccccccccc"), 20, TODAY_TIME)
		assert.is_true(#lines >= 3)
		for _, l in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(l) <= 20)
		end
	end)
end)

describe("ui.kanban._render_column_lines", function()
	it("カードが無ければプレースホルダー1行のみ", function()
		local lines, ranges, spans = kanban._render_column_lines({}, 20, TODAY_TIME)
		assert.are.same({ "  (no tasks)" }, lines)
		assert.are.same({}, ranges)
		assert.are.same({}, spans)
	end)

	it("各カードを罫線で囲んだ範囲として返す", function()
		local t1 = task("- [ ] First")
		t1.id = "id0001"
		local t2 = task("- [ ] Second +work")
		t2.id = "id0002"
		local cards = {
			{ task = t1, source = "todo", section = "Today" },
			{ task = t2, source = "todo", section = "Today" },
		}
		local lines, ranges = kanban._render_column_lines(cards, 20, TODAY_TIME)

		assert.are.same(2, #ranges)
		assert.are.same("id0001", ranges[1].task_id)
		assert.are.same(1, ranges[1].start_line)
		assert.are.same("┌" .. string.rep("─", 18) .. "┐", lines[ranges[1].start_line])
		assert.are.same("└" .. string.rep("─", 18) .. "┘", lines[ranges[1].end_line])

		assert.are.same("id0002", ranges[2].task_id)
		assert.is_true(ranges[2].start_line > ranges[1].end_line)
	end)

	it("優先度のハイライトスパンはバッファ座標(罫線オフセット込み)で返る", function()
		local t = task("- [ ] (B) Task")
		t.id = "idB"
		local lines, ranges, spans = kanban._render_column_lines({ { task = t, source = "todo" } }, 30, TODAY_TIME)
		assert.are.same(1, #spans)
		assert.are.same("GTodoPriorityB", spans[1].hl_group)
		assert.are.same(ranges[1].start_line + 1, spans[1].line)
		local body_line = lines[spans[1].line]
		assert.are.same("(B)", body_line:sub(spans[1].start_col + 1, spans[1].end_col))
	end)
end)

describe("ui.kanban._build_columns", function()
	local function todo_data_from(sections)
		local data = { sections = {}, section_order = {} }
		for name, items in pairs(sections) do
			data.sections[name] = items
			table.insert(data.section_order, name)
		end
		return data
	end

	it("未完了タスクは対応するtodo.mdセクションの列へ入る", function()
		local todo_data = todo_data_from({
			Today = { { type = "task", task = task("- [ ] Today task") } },
			Next = { { type = "task", task = task("- [ ] Next task") } },
			Waiting = { { type = "task", task = task("- [ ] Waiting task wait:bob") } },
			Someday = { { type = "task", task = task("- [ ] Someday task") } },
		})
		local done_data = { sections = {}, section_order = {} }

		local columns = kanban._build_columns(todo_data, done_data, SECTIONS)
		local by_key = {}
		for _, c in ipairs(columns) do
			by_key[c.key] = c
		end

		assert.are.same(
			{ "SOMEDAY", "NEXT", "TODAY", "WAITING", "DONE" },
			vim.tbl_map(function(c)
				return c.key
			end, columns)
		)

		assert.are.same(1, #by_key.TODAY.cards)
		assert.are.same("Today task", by_key.TODAY.cards[1].task.content)
		assert.are.same(1, #by_key.NEXT.cards)
		assert.are.same(1, #by_key.WAITING.cards)
		assert.are.same(1, #by_key.SOMEDAY.cards)
		assert.are.same(0, #by_key.DONE.cards)
	end)

	it(
		"status=xのtodo.mdタスクはセクションに関わらずDone列へ集約される(二重表示を避ける)",
		function()
			local todo_data = todo_data_from({
				Today = { { type = "task", task = task("- [x] Finished today completed_at:2026-08-24") } },
				Next = {},
				Waiting = {},
				Someday = {},
			})
			local done_data = { sections = {}, section_order = {} }

			local columns = kanban._build_columns(todo_data, done_data, SECTIONS)
			local by_key = {}
			for _, c in ipairs(columns) do
				by_key[c.key] = c
			end

			assert.are.same(0, #by_key.TODAY.cards)
			assert.are.same(1, #by_key.DONE.cards)
			assert.are.same("todo", by_key.DONE.cards[1].source)
			assert.are.same("Today", by_key.DONE.cards[1].section)
		end
	)

	it("done.mdのタスクはsource=doneとしてDone列へ入る", function()
		local todo_data = { sections = {}, section_order = {} }
		local done_data = todo_data_from({
			["2026-08"] = { { type = "task", task = task("- [x] Old done done:2026-08-01") } },
		})

		local columns = kanban._build_columns(todo_data, done_data, SECTIONS)
		local done_col = columns[5]
		assert.are.same(1, #done_col.cards)
		assert.are.same("done", done_col.cards[1].source)
		assert.is_nil(done_col.cards[1].section)
	end)

	it("Done列はdone(またはcompleted_at)の降順に並ぶ", function()
		local todo_data = todo_data_from({
			Today = { { type = "task", task = task("- [x] Recent completed_at:2026-08-24") } },
			Next = {},
			Waiting = {},
			Someday = {},
		})
		local done_data = todo_data_from({
			["2026-07"] = { { type = "task", task = task("- [x] Older done:2026-07-01") } },
		})

		local columns = kanban._build_columns(todo_data, done_data, SECTIONS)
		local done_col = columns[5]
		assert.are.same(2, #done_col.cards)
		assert.are.same("Recent", done_col.cards[1].task.content)
		assert.are.same("Older", done_col.cards[2].task.content)
	end)
end)

describe("ui.kanban._compute_layout", function()
	it("十分な幅があれば5列すべてを表示する", function()
		local layout = kanban._compute_layout(5, 200, 40)
		assert.are.same(5, layout.visible_count)
	end)

	it("狭い幅では表示列数を減らす", function()
		local layout = kanban._compute_layout(5, 40, 40)
		assert.is_true(layout.visible_count < 5)
		assert.is_true(layout.visible_count >= 1)
	end)

	it("極端に狭くても最低1列は表示する", function()
		local layout = kanban._compute_layout(5, 5, 40)
		assert.are.same(1, layout.visible_count)
	end)
end)

describe("ui.kanban._clamp_page_offset", function()
	it("フォーカス列が既に可視範囲ならoffsetを変えない", function()
		assert.are.same(1, kanban._clamp_page_offset(2, 3, 5, 1))
	end)

	it("フォーカス列が右にはみ出す場合は右へずらす", function()
		assert.are.same(2, kanban._clamp_page_offset(5, 3, 5, 0))
	end)

	it("フォーカス列が左にはみ出す場合は左へずらす", function()
		assert.are.same(0, kanban._clamp_page_offset(1, 3, 5, 2))
	end)

	it("offsetは総列数-可視列数を超えない", function()
		assert.are.same(2, kanban._clamp_page_offset(5, 3, 5, 10))
	end)
end)

describe("ui.kanban._find_card_at_line", function()
	local ranges = {
		{ task_id = "a", start_line = 1, end_line = 3 },
		{ task_id = "b", start_line = 4, end_line = 6 },
	}

	it("行番号を含むカードを返す", function()
		assert.are.same("a", kanban._find_card_at_line(ranges, 2).task_id)
		assert.are.same("b", kanban._find_card_at_line(ranges, 6).task_id)
	end)

	it("どのカードにも属さない行は nil", function()
		assert.is_nil(kanban._find_card_at_line(ranges, 100))
	end)
end)

describe("ui.kanban._adjacent_card_index", function()
	local ranges = {
		{ task_id = "a", start_line = 1, end_line = 3 },
		{ task_id = "b", start_line = 4, end_line = 6 },
		{ task_id = "c", start_line = 7, end_line = 9 },
	}

	it("現在のカードから次/前のカードの先頭行へ移動する", function()
		assert.are.same(4, kanban._adjacent_card_index(ranges, 2, 1))
		assert.are.same(1, kanban._adjacent_card_index(ranges, 5, -1))
	end)

	it("先頭/末尾では nil を返す(移動しない)", function()
		assert.is_nil(kanban._adjacent_card_index(ranges, 2, -1))
		assert.is_nil(kanban._adjacent_card_index(ranges, 8, 1))
	end)

	it("カードの外にカーソルがある場合は移動方向の最寄りカードへ飛ぶ", function()
		assert.are.same(1, kanban._adjacent_card_index(ranges, 0, 1))
		assert.are.same(7, kanban._adjacent_card_index(ranges, 100, -1))
	end)

	it("カードが1つも無ければ nil", function()
		assert.is_nil(kanban._adjacent_card_index({}, 1, 1))
	end)
end)
