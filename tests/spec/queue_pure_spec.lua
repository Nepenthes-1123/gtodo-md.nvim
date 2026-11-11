-- ui/queue.lua から切り出した純関数の単体テスト。
-- バッファやウィンドウに触れないため open_queue() 全体を起動せずに検証できる。

local queue = require("gtodo-md.ui.queue")
local task_mod = require("gtodo-md.task")
local utils = require("gtodo-md.utils")

-- 基準日は固定にして曜日・日数差の期待値を安定させる (2025-06-10 は火曜)
local TODAY_STR = "2025-06-10"
local TODAY_TIME = utils.date_to_time(TODAY_STR)

-- タスク行から collect 済みエントリ相当のテーブルを作る
local function entry(line, filepath, lnum)
	local task = task_mod.parse(line)
	assert.is_not_nil(task, "テスト用のタスク行がパースできない: " .. line)
	return {
		task = task,
		filepath = filepath or "/data/todo.md",
		lnum = lnum or 1,
		mark_id = lnum or 1,
		bufnr = 7,
	}
end

local function contents(entries)
	local out = {}
	for _, e in ipairs(entries) do
		table.insert(out, e.task.content)
	end
	return out
end

describe("ui.queue._match_queue_task", function()
	it("due モードでは due 付きの未完了タスクだけを返す", function()
		local matched = queue._match_queue_task("- [ ] pay bill due:2025-06-10", "due")
		assert.is_not_nil(matched)
		assert.are.same("pay bill", matched.content)

		assert.is_nil(queue._match_queue_task("- [ ] no due tag", "due"))
		assert.is_nil(queue._match_queue_task("- [ ] waiting only wait:bob", "due"))
	end)

	it("wait モードでは wait 付きの未完了タスクだけを返す", function()
		local matched = queue._match_queue_task("- [ ] ask review wait:bob", "wait")
		assert.is_not_nil(matched)
		assert.are.same("bob", matched.wait)

		assert.is_nil(queue._match_queue_task("- [ ] due only due:2025-06-10", "wait"))
	end)

	it("完了済みタスクは対象外", function()
		assert.is_nil(queue._match_queue_task("- [x] done task due:2025-06-10", "due"))
		assert.is_nil(queue._match_queue_task("- [x] done task wait:bob", "wait"))
	end)

	it("タスクでない行は対象外", function()
		assert.is_nil(queue._match_queue_task("## Today", "due"))
		assert.is_nil(queue._match_queue_task("", "due"))
	end)
end)

describe("ui.queue._group_entries (due モード)", function()
	local entries, groups

	before_each(function()
		entries = {
			entry("- [ ] later far due:2025-07-20"),
			entry("- [ ] overdue newer due:2025-06-09"),
			entry("- [ ] today task due:2025-06-10"),
			entry("- [ ] overdue older due:2025-06-01"),
			entry("- [ ] week edge due:2025-06-17"),
			entry("- [ ] later edge due:2025-06-18"),
			entry("- [ ] today second due:2025-06-10"),
			entry("- [ ] tomorrow task due:2025-06-11"),
		}
		groups = queue._group_entries(entries, "due", TODAY_TIME)
	end)

	it(
		"今日より前は overdue、今日以降は全て by_date へ振り分ける(7日の区切りは無い)",
		function()
			assert.are.same({ "overdue older", "overdue newer" }, contents(groups.overdue))
			assert.are.same(
				{ "2025-06-10", "2025-06-11", "2025-06-17", "2025-06-18", "2025-07-20" },
				groups.sorted_dates
			)
		end
	)

	it("7日を超える日付も by_date に日付ごとのキーで含まれる", function()
		assert.are.same({ "week edge" }, contents(groups.by_date["2025-06-17"]))
		assert.are.same({ "later edge" }, contents(groups.by_date["2025-06-18"]))
		assert.are.same({ "later far" }, contents(groups.by_date["2025-07-20"]))
	end)

	it("overdue は due の昇順にソートされる", function()
		assert.are.same("2025-06-01", groups.overdue[1].task.due)
		assert.are.same("2025-06-09", groups.overdue[2].task.due)
	end)

	it("同じ日付のタスクは元の並び順を保つ", function()
		assert.are.same({ "today task", "today second" }, contents(groups.by_date["2025-06-10"]))
	end)

	it("7日を超えた先の同じ日付のタスクもまとめられる", function()
		local far_entries = {
			entry("- [ ] exam due:2025-09-12"),
			entry("- [ ] dentist due:2025-09-12"),
		}
		local far_groups = queue._group_entries(far_entries, "due", TODAY_TIME)
		assert.are.same({ "2025-09-12" }, far_groups.sorted_dates)
		assert.are.same({ "exam", "dentist" }, contents(far_groups.by_date["2025-09-12"]))
	end)

	it("wait モード用のグループは空のまま", function()
		assert.are.same({}, groups.by_person)
		assert.are.same({}, groups.sorted_persons)
	end)

	it("エントリが空なら全グループが空になる", function()
		local empty = queue._group_entries({}, "due", TODAY_TIME)
		assert.are.same({}, empty.overdue)
		assert.are.same({}, empty.by_date)
		assert.are.same({}, empty.sorted_dates)
	end)
end)

describe("ui.queue._group_entries (wait モード)", function()
	local groups

	before_each(function()
		groups = queue._group_entries({
			entry("- [ ] ask zoe wait:zoe"),
			entry("- [ ] ask bob wait:bob"),
			entry("- [ ] ask alice wait:alice"),
			entry("- [ ] ask bob again wait:bob"),
		}, "wait", TODAY_TIME)
	end)

	it("担当者ごとにグルーピングし、担当者名を昇順にソートする", function()
		assert.are.same({ "alice", "bob", "zoe" }, groups.sorted_persons)
		assert.are.same({ "ask bob", "ask bob again" }, contents(groups.by_person["bob"]))
	end)

	it("due モード用のグループは空のまま", function()
		assert.are.same({}, groups.overdue)
		assert.are.same({}, groups.by_date)
		assert.are.same({}, groups.sorted_dates)
	end)
end)

describe("ui.queue._build_display (due モード)", function()
	local lines, hls, line_map

	before_each(function()
		local entries = {
			entry("- [ ] overdue task +work @office due:2025-06-01", "/data/inbox.md", 3),
			entry("- [ ] today task due:2025-06-10", "/data/todo.md", 5),
			entry("- [ ] tomorrow task due:2025-06-11", "/data/todo.md", 6),
			entry("- [ ] in 3 days due:2025-06-13", "/data/todo.md", 7),
			entry("- [ ] later task due:2025-07-20", "/data/todo.md", 8),
		}
		local groups = queue._group_entries(entries, "due", TODAY_TIME)
		lines, hls, line_map = queue._build_display("due", groups, TODAY_STR, TODAY_TIME)
	end)

	it("ヘッダーに今日の日付を表示する", function()
		assert.are.same(" Queue (Due)  2025-06-10", lines[1])
		assert.are.same(string.rep("─", 46), lines[2])
	end)

	it("期限切れは超過日数付きで表示する", function()
		assert.is_truthy(vim.tbl_contains(lines, " 期限切れ"))
		assert.is_truthy(vim.tbl_contains(lines, "  ⚠ overdue task +work @office (9日超過)"))
	end)

	it("日付見出しは今日/明日/N日後を曜日付きで表示する", function()
		assert.is_truthy(vim.tbl_contains(lines, " 今日 (6/10 火)"))
		assert.is_truthy(vim.tbl_contains(lines, " 明日 (6/11 水)"))
		assert.is_truthy(vim.tbl_contains(lines, " 6/13 金 (3日後)"))
	end)

	it(
		"7日を超える日付にも同じ形式の見出しが付き、それ以降への特別扱いは無い",
		function()
			assert.is_falsy(vim.tbl_contains(lines, " それ以降"))
			assert.is_truthy(vim.tbl_contains(lines, " 7/20 日 (40日後)"))
			assert.is_truthy(vim.tbl_contains(lines, "  ▶ later task"))
		end
	)

	it("30日を大きく超える日付(40日後)の見出しはComment(低視覚重み)になる", function()
		local idx
		for i, line in ipairs(lines) do
			if line == " 7/20 日 (40日後)" then
				idx = i - 1
				break
			end
		end
		assert.is_not_nil(idx)
		local found
		for _, hl in ipairs(hls) do
			if hl[1] == idx then
				found = hl[2]
			end
		end
		assert.are.same("Comment", found)
	end)

	it("タスク行だけが line_map に登録される", function()
		local mapped = 0
		for idx, source in pairs(line_map) do
			mapped = mapped + 1
			local text = lines[idx + 1]
			assert.is_truthy(text:match("^  ▶ ") or text:match("^  ⚠ "), "タスク行でない: " .. text)
			assert.is_truthy(source.filepath)
			assert.is_truthy(source.original_line)
			assert.are.same(7, source.bufnr)
		end
		assert.are.same(5, mapped)
	end)

	it("line_map は元のファイル・行番号を保持する", function()
		for idx, source in pairs(line_map) do
			if lines[idx + 1]:match("overdue task") then
				assert.are.same("/data/inbox.md", source.filepath)
				assert.are.same(3, source.lnum)
			end
		end
	end)

	it("ハイライトは行インデックス(0基点)とハイライトグループの組", function()
		assert.are.same({ 0, "Title" }, hls[1])
		assert.are.same({ 1, "Comment" }, hls[2])
	end)

	it("タスクが無い場合は専用メッセージを表示する", function()
		local empty_groups = queue._group_entries({}, "due", TODAY_TIME)
		local empty_lines = queue._build_display("due", empty_groups, TODAY_STR, TODAY_TIME)
		assert.are.same({
			" Queue (Due)  2025-06-10",
			string.rep("─", 46),
			"",
			"  期限付きタスクはありません",
		}, empty_lines)
	end)
end)

describe("ui.queue._build_display 日付見出しのハイライト閾値(#150 フォローアップ)", function()
	local lines, hls

	before_each(function()
		local entries = {
			entry("- [ ] boundary near due:2025-07-10"), -- 30日後(閾値以内)
			entry("- [ ] boundary far due:2025-07-11"), -- 31日後(閾値超え)
		}
		local groups = queue._group_entries(entries, "due", TODAY_TIME)
		lines, hls = queue._build_display("due", groups, TODAY_STR, TODAY_TIME)
	end)

	local function hl_of_line_containing(pattern)
		for i, line in ipairs(lines) do
			if line:find(pattern, 1, true) then
				for _, hl in ipairs(hls) do
					if hl[1] == i - 1 then
						return hl[2]
					end
				end
			end
		end
		return nil
	end

	it("30日後(閾値以内)はDiagnosticInfoのまま", function()
		assert.are.same("DiagnosticInfo", hl_of_line_containing("(30日後)"))
	end)

	it("31日後(閾値超え)はComment(低視覚重み)へ格下げされる", function()
		assert.are.same("Comment", hl_of_line_containing("(31日後)"))
	end)

	it("30日後(閾値以内)のタスク行は通常色(ハイライト無し)のまま", function()
		assert.is_nil(hl_of_line_containing("boundary near"))
	end)

	it("31日後(閾値超え)のタスク行も見出しと揃えてCommentになる", function()
		assert.are.same("Comment", hl_of_line_containing("boundary far"))
	end)
end)

describe("ui.queue._build_display (wait モード)", function()
	it("担当者ごとの見出しとタスクを表示する", function()
		local groups = queue._group_entries({
			entry("- [ ] ask bob +work @office wait:bob", "/data/todo.md", 9),
			entry("- [ ] ask alice wait:alice", "/data/inbox.md", 4),
		}, "wait", TODAY_TIME)
		local lines, _, line_map = queue._build_display("wait", groups, TODAY_STR, TODAY_TIME)

		assert.are.same(" Queue (Wait) 2025-06-10", lines[1])
		assert.is_truthy(vim.tbl_contains(lines, " alice 待ち"))
		assert.is_truthy(vim.tbl_contains(lines, " bob 待ち"))
		assert.is_truthy(vim.tbl_contains(lines, "  ▶ ask bob +work @office"))

		local mapped = 0
		for _ in pairs(line_map) do
			mapped = mapped + 1
		end
		assert.are.same(2, mapped)
	end)

	it("待ちタスクが無い場合は専用メッセージを表示する", function()
		local groups = queue._group_entries({}, "wait", TODAY_TIME)
		local lines = queue._build_display("wait", groups, TODAY_STR, TODAY_TIME)
		assert.are.same({
			" Queue (Wait) 2025-06-10",
			string.rep("─", 46),
			"",
			"  誰かの作業を待っているタスクはありません",
		}, lines)
	end)
end)

describe("ui.queue 純関数の既定引数", function()
	it("today を省略すると実際の今日を基準にする", function()
		local today = os.date("%Y-%m-%d")
		local groups = queue._group_entries({ entry("- [ ] today task due:" .. today) }, "due")
		assert.are.same({ today }, groups.sorted_dates)

		local weekday = ({ "日", "月", "火", "水", "木", "金", "土" })[tonumber(os.date("%w")) + 1]
		local expected_label =
			string.format(" 今日 (%d/%d %s)", tonumber(today:sub(6, 7)), tonumber(today:sub(9, 10)), weekday)

		local lines = queue._build_display("due", groups)
		assert.are.same(" Queue (Due)  " .. today, lines[1])
		assert.is_truthy(vim.tbl_contains(lines, expected_label))
	end)
end)

-- 日付として解釈できない期日 (`due:someday`・存在しない日付 `due:2026-02-30`)。
-- 以前は前者があると例外で Queue 自体を開けず、後者は os.time が補正した別の日付
-- (3/2) で日数や期限切れを判定しながら、見出しには書いたとおりの日付を出していた。
-- CLI (gtodo queue) と同じく、落とさず別のグループとして見せる。
describe("ui.queue 解釈できない期日", function()
	local entries = {
		entry("- [ ] いつか due:someday", nil, 1),
		entry("- [ ] 存在しない日付 due:2025-02-30", nil, 2),
		entry("- [ ] 13月 due:2025-13-01", nil, 3),
		entry("- [ ] 明日 due:2025-06-11", nil, 4),
		entry("- [ ] 期限切れ due:2025-06-01", nil, 5),
	}

	it("別のグループへ分け、期限切れや日付のグループには入れない", function()
		local groups = queue._group_entries(entries, "due", TODAY_TIME)
		assert.are.same({ "いつか", "存在しない日付", "13月" }, contents(groups.invalid))
		assert.are.same({ "期限切れ" }, contents(groups.overdue))
		assert.are.same({ "2025-06-11" }, groups.sorted_dates)
	end)

	it("見出しと、書かれていた期日を表示する", function()
		local groups = queue._group_entries(entries, "due", TODAY_TIME)
		local lines, _, line_map = queue._build_display("due", groups, TODAY_STR, TODAY_TIME)
		local heading
		for i, l in ipairs(lines) do
			if l == " 期日を解釈できない" then
				heading = i
			end
		end
		assert.is_not_nil(heading, vim.inspect(lines))
		assert.are.same("  ▶ いつか (due:someday)", lines[heading + 2])
		assert.are.same("  ▶ 存在しない日付 (due:2025-02-30)", lines[heading + 3])
		-- ジャンプ先も他のグループと同じく持つ
		assert.are.same(1, line_map[heading + 1].lnum)
	end)

	it("解釈できない期日だけでも「期限付きタスクはありません」にしない", function()
		local groups = queue._group_entries({ entries[1] }, "due", TODAY_TIME)
		local lines = queue._build_display("due", groups, TODAY_STR, TODAY_TIME)
		assert.is_false(vim.tbl_contains(lines, "  期限付きタスクはありません"))
	end)
end)

describe("utils.date_to_time", function()
	it("日付として解釈できない値には nil を返す", function()
		assert.is_nil(utils.date_to_time("someday"))
		assert.is_nil(utils.date_to_time("2025-02-30"))
		assert.is_nil(utils.date_to_time("2025-13-01"))
		assert.is_nil(utils.date_to_time("2025-00-10"))
		assert.is_nil(utils.date_to_time("2025-06-10x"))
		assert.is_nil(utils.date_to_time(""))
		assert.is_nil(utils.date_to_time(nil))
	end)

	it("実在する日付はその日の 0 時を返す", function()
		assert.are.equal(os.time({ year = 2024, month = 2, day = 29, hour = 0 }), utils.date_to_time("2024-02-29"))
		assert.are.equal("2025-06-10", os.date("%Y-%m-%d", utils.date_to_time("2025-06-10")))
	end)
end)
