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

	it("今日より前は overdue、7日後までは by_date、それ以降は later へ振り分ける", function()
		assert.are.same({ "overdue older", "overdue newer" }, contents(groups.overdue))
		assert.are.same({ "later edge", "later far" }, contents(groups.later))
		assert.are.same({ "2025-06-10", "2025-06-11", "2025-06-17" }, groups.sorted_dates)
	end)

	it("ちょうど7日後は by_date に含まれ、8日後は later になる(境界)", function()
		assert.are.same({ "week edge" }, contents(groups.by_date["2025-06-17"]))
		assert.is_nil(groups.by_date["2025-06-18"])
	end)

	it("overdue と later は due の昇順にソートされる", function()
		assert.are.same("2025-06-01", groups.overdue[1].task.due)
		assert.are.same("2025-06-09", groups.overdue[2].task.due)
		assert.are.same("2025-06-18", groups.later[1].task.due)
		assert.are.same("2025-07-20", groups.later[2].task.due)
	end)

	it("同じ日付のタスクは元の並び順を保つ", function()
		assert.are.same({ "today task", "today second" }, contents(groups.by_date["2025-06-10"]))
	end)

	it("wait モード用のグループは空のまま", function()
		assert.are.same({}, groups.by_person)
		assert.are.same({}, groups.sorted_persons)
	end)

	it("エントリが空なら全グループが空になる", function()
		local empty = queue._group_entries({}, "due", TODAY_TIME)
		assert.are.same({}, empty.overdue)
		assert.are.same({}, empty.later)
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
		assert.are.same({}, groups.later)
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

	it("それ以降のタスクには due:M/D を付ける", function()
		assert.is_truthy(vim.tbl_contains(lines, " それ以降"))
		assert.is_truthy(vim.tbl_contains(lines, "  ▶ later task  due:7/20"))
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
