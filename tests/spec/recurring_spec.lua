-- 定期タスク (#158): テンプレートのフロントマターの読み取り・「その日に作るか」の判定 (logic/recurring.lua) と、
-- 日次の整理で inbox.md へ足す処理 (recurring.lua) を固定する。
--
-- 曜日の確認に使う日付: 2026-11-19 は木曜、2026-11-10 は火曜、2026-11-27 は金曜、2026-11-30 は月曜、
-- 2026-02-28 は土曜 (2026 年は閏年でない)、2028-02-29 は火曜。

local logic = require("gtodo-md.logic.recurring")

-- serialize が末尾に付ける id:XXXXXX を除く。
local function strip_id(line)
	return (line:gsub(" id:%x+$", ""))
end

describe("logic.recurring", function()
	describe("parse_repeat", function()
		it(
			"曜日・日・月末・何週目かの曜日・毎年の月日を読み、大文字小文字を区別しない",
			function()
				local rules = assert(logic.parse_repeat("Mon, 15 ,end, 2nd TUE, last fri, 04-01, 4-1"))
				assert.are.same({
					{ kind = "weekday", weekday = 1 },
					{ kind = "month_day", day = 15 },
					{ kind = "month_end" },
					{ kind = "nth_weekday", nth = 2, weekday = 2 },
					{ kind = "nth_weekday", nth = -1, weekday = 5 },
					{ kind = "year_day", month = 4, day = 1 },
					{ kind = "year_day", month = 4, day = 1 },
				}, rules)
			end
		)

		it("読めない項目はエラーにする", function()
			for _, spec in ipairs({
				"",
				"  ",
				"funday",
				"0",
				"32",
				"5th mon",
				"2nd",
				"02-30",
				"13-01",
				"mon,",
				"mon,,tue",
			}) do
				local rules, err = logic.parse_repeat(spec)
				assert.is_nil(rules, spec)
				assert.is_string(err, spec)
			end
		end)

		it("閏年にしか無い 02-29 は受け付ける", function()
			assert.is_not_nil(logic.parse_repeat("02-29"))
		end)
	end)

	describe("parse_frontmatter", function()
		it("先頭が --- でなければフロントマターは無い", function()
			local fm, body = logic.parse_frontmatter({ "<!--", "---", "type: recurring", "---" })
			assert.is_nil(fm)
			assert.are.equal(1, body)
		end)

		it("閉じる --- が無ければフロントマターは無い", function()
			local fm, body = logic.parse_frontmatter({ "---", "type: recurring", "- [ ] a" })
			assert.is_nil(fm)
			assert.are.equal(1, body)
		end)

		it("キー・values の字下げした行・引用符・コメント・CRLF を読む", function()
			local fm, body = logic.parse_frontmatter({
				"---\r",
				"type: recurring\r",
				"# コメント",
				'repeat: "mon, thu"',
				"values:",
				"  project: site",
				"",
				"  # 値の途中のコメント",
				"  assignee: '田中'",
				"other: x",
				"  ignored: y",
				"---",
				"- [ ] a",
			})
			assert.are.same({ type = "recurring", ["repeat"] = "mon, thu", values = "", other = "x" }, fm.fields)
			assert.are.same({ project = "site", assignee = "田中" }, fm.values)
			assert.are.equal(13, body)
		end)
	end)

	describe("read_definition", function()
		it(
			"フロントマターの無いテンプレートは定期タスクではなく、本文はすべての行",
			function()
				local def = logic.read_definition({ "- [ ] a", "- [ ] b" })
				assert.is_false(def.recurring)
				assert.is_nil(def.error)
				assert.are.same({ "- [ ] a", "- [ ] b" }, def.body)
				assert.are.same({}, def.values)
			end
		)

		it("type: recurring と repeat があれば定期タスク", function()
			local def = logic.read_definition({ "---", "type: recurring", "repeat: mon", "---", "- [ ] a" })
			assert.is_true(def.recurring)
			assert.is_nil(def.error)
			assert.are.equal("mon", def.repeat_text)
			assert.are.same({ { kind = "weekday", weekday = 1 } }, def.rules)
			assert.are.same({ "- [ ] a" }, def.body)
		end)

		it("定期タスクでなくても values は読む (手で挿入するときの初期値)", function()
			local def = logic.read_definition({ "---", "values:", "  project: site", "---", "- [ ] {{project}}" })
			assert.is_false(def.recurring)
			assert.is_nil(def.error)
			assert.are.same({ project = "site" }, def.values)
		end)

		it("書き間違いは理由を返す", function()
			local cases = {
				{ { "---", "repeat: mon", "---" }, "type: recurring" },
				{ { "---", "type: weekly", "repeat: mon", "---" }, "unknown type" },
				{ { "---", "type: recurring", "---" }, "needs 'repeat:'" },
				{ { "---", "type: recurring", "repeat: someday", "---" }, "is not a day" },
			}
			for _, case in ipairs(cases) do
				local def = logic.read_definition(case[1])
				assert.is_truthy(def.error and def.error:find(case[2], 1, true), vim.inspect(case[1]))
			end
		end)
	end)

	describe("occurs_on", function()
		local function on(spec, date)
			return logic.occurs_on(assert(logic.parse_repeat(spec)), date)
		end

		it("曜日", function()
			assert.is_true(on("thu", "2026-11-19"))
			assert.is_false(on("thu", "2026-11-20"))
			assert.is_true(on("mon, thu", "2026-11-30"))
		end)

		it("その月に無い日は月末に作る", function()
			assert.is_true(on("31", "2026-11-30"))
			assert.is_false(on("31", "2026-11-29"))
			assert.is_true(on("30", "2026-02-28"))
			assert.is_true(on("30", "2028-02-29"))
			assert.is_false(on("30", "2028-02-28"))
			assert.is_true(on("31", "2026-12-31"))
		end)

		it("end は月末", function()
			assert.is_true(on("end", "2026-11-30"))
			assert.is_true(on("end", "2026-02-28"))
			assert.is_false(on("end", "2028-02-28"))
		end)

		it("何週目かの曜日", function()
			assert.is_true(on("2nd tue", "2026-11-10"))
			assert.is_false(on("2nd tue", "2026-11-03"))
			assert.is_true(on("1st tue", "2026-11-03"))
			assert.is_true(on("4th thu", "2026-11-26"))
			assert.is_true(on("last fri", "2026-11-27"))
			assert.is_false(on("last fri", "2026-11-20"))
			assert.is_true(on("last mon", "2026-11-30"))
		end)

		it("毎年の月日 (02-29 は閏年でない年は 2/28)", function()
			assert.is_true(on("04-01", "2027-04-01"))
			assert.is_false(on("04-01", "2027-05-01"))
			assert.is_true(on("02-29", "2026-02-28"))
			assert.is_true(on("02-29", "2028-02-29"))
			assert.is_false(on("02-29", "2028-02-28"))
		end)

		it("読めない日付は当たらない", function()
			assert.is_false(on("mon", "2026-02-30"))
			assert.is_false(on("mon", "today"))
		end)
	end)

	describe("latest_occurrence", function()
		local function latest(spec, after, today)
			return logic.latest_occurrence(assert(logic.parse_repeat(spec)), after, today)
		end

		it("まだ確かめていなければ、今日の分だけを見る", function()
			assert.are.equal("2026-11-19", latest("thu", nil, "2026-11-19"))
			assert.is_nil(latest("wed", nil, "2026-11-19"))
		end)

		it("確かめた日より後に逃した回があれば、最後の 1 回分", function()
			assert.are.equal("2026-11-16", latest("mon, wed", "2026-11-10", "2026-11-17"))
			assert.are.equal("2026-11-18", latest("mon, wed", "2026-11-10", "2026-11-19"))
		end)

		it("確かめた日そのものは含めない", function()
			assert.is_nil(latest("thu", "2026-11-19", "2026-11-19"))
			assert.is_nil(latest("thu", "2026-11-20", "2026-11-19"))
		end)

		it("1 年より前に確かめていても、最後の回は見つかる", function()
			assert.are.equal("2026-04-01", latest("04-01", "2020-01-01", "2026-11-19"))
		end)
	end)

	describe("next_occurrence", function()
		it("その日より後で最初に当たる日", function()
			assert.are.equal("2026-11-26", logic.next_occurrence(assert(logic.parse_repeat("thu")), "2026-11-19"))
			assert.are.equal("2027-04-01", logic.next_occurrence(assert(logic.parse_repeat("04-01")), "2026-11-19"))
		end)
	end)
end)

describe("recurring.create_due_tasks", function()
	local data_dir
	local recurring
	local state
	local notices
	local real_notify

	local function write_template(name, lines)
		vim.fn.mkdir(data_dir .. "/templates", "p")
		vim.fn.writefile(lines, data_dir .. "/templates/" .. name .. ".md")
	end

	local function inbox_tasks()
		local result = {}
		for _, line in ipairs(vim.fn.readfile(data_dir .. "/inbox.md")) do
			if line:match("^%- %[") then
				table.insert(result, strip_id(line))
			end
		end
		return result
	end

	local function notices_with(text)
		local found = {}
		for _, n in ipairs(notices) do
			if n.msg:find(text, 1, true) then
				table.insert(found, n)
			end
		end
		return found
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		require("gtodo-md.config").setup({ data_dir = data_dir })
		vim.fn.writefile({ "# Inbox", "", "- [ ] 既存のタスク" }, data_dir .. "/inbox.md")
		recurring = require("gtodo-md.recurring")
		state = require("gtodo-md.state")
		notices = {}
		real_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notices, { msg = msg, level = level })
		end
	end)

	after_each(function()
		vim.notify = real_notify
		vim.fn.delete(data_dir, "rf")
	end)

	it(
		"当たる日に inbox.md へ足し、相対の期日はその回の日から数え、確かめた日を記録する",
		function()
			write_template("weekly", {
				"---",
				"type: recurring",
				"repeat: thu",
				"---",
				"<!-- メモ -->",
				"- [ ] 週報を書く +work due:+1d",
			})
			assert.are.equal(1, recurring.create_due_tasks("2026-11-19"))
			assert.are.same({ "- [ ] 既存のタスク", "- [ ] 週報を書く +work due:2026-11-20" }, inbox_tasks())
			assert.are.same({ weekly = "2026-11-19" }, state.read_recurring())
			assert.are.equal(1, #notices_with("Added 1 recurring task(s)"))

			-- 同じ日にもう一度呼んでも作らない。
			assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
			assert.are.equal(2, #inbox_tasks())
		end
	)

	it(
		"しばらく開かなかった後は、逃した回の最後の 1 回分だけを、その回の日の期日で作る",
		function()
			write_template("standup", { "---", "type: recurring", "repeat: mon, wed", "---", "- [ ] 朝会 due:+0d" })
			state.write_recurring({ standup = "2026-11-10" })
			assert.are.equal(1, recurring.create_due_tasks("2026-11-19"))
			assert.are.same({ "- [ ] 既存のタスク", "- [ ] 朝会 due:2026-11-18" }, inbox_tasks())
			assert.are.same({ standup = "2026-11-19" }, state.read_recurring())
		end
	)

	it("作ったばかりのテンプレートは、昨日までの回をさかのぼって作らない", function()
		write_template("standup", { "---", "type: recurring", "repeat: wed", "---", "- [ ] 朝会" })
		assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ "- [ ] 既存のタスク" }, inbox_tasks())
		-- 確かめた日は記録する (次から、逃した回を数えられるように)。
		assert.are.same({ standup = "2026-11-19" }, state.read_recurring())
	end)

	it("{{名前}} は values: の値で埋める", function()
		write_template("site", {
			"---",
			"type: recurring",
			"repeat: thu",
			"values:",
			"  project: +site",
			"  context:",
			"  who: 田中",
			"---",
			"- [ ] {{who}} さんに確認 {{project}} {{context}}",
		})
		assert.are.equal(1, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ "- [ ] 既存のタスク", "- [ ] 田中 さんに確認 +site" }, inbox_tasks())
	end)

	it("値の無い {{名前}} があれば作らず、知らせ、記録も進めない", function()
		write_template("site", { "---", "type: recurring", "repeat: thu", "---", "- [ ] 確認 {{project}}" })
		state.write_recurring({ site = "2026-11-12" })
		assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ "- [ ] 既存のタスク" }, inbox_tasks())
		assert.are.same({ site = "2026-11-12" }, state.read_recurring())
		assert.are.equal(1, #notices_with("site: no value for {{project}}"))
	end)

	it("読めない定期タスクは知らせて飛ばし、ほかのテンプレートは作る", function()
		write_template("broken", { "---", "type: recurring", "repeat: someday", "---", "- [ ] x" })
		write_template("ok", { "---", "type: recurring", "repeat: thu", "---", "- [ ] y" })
		assert.are.equal(1, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ "- [ ] 既存のタスク", "- [ ] y" }, inbox_tasks())
		assert.are.same({ ok = "2026-11-19" }, state.read_recurring())
		assert.are.equal(1, #notices_with("broken: repeat:"))
	end)

	it("複数のテンプレートは名前の順に足す", function()
		write_template("b", { "---", "type: recurring", "repeat: thu", "---", "- [ ] B" })
		write_template("a", { "---", "type: recurring", "repeat: thu", "---", "- [ ] A1", "- [ ] A2" })
		assert.are.equal(3, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ "- [ ] 既存のタスク", "- [ ] A1", "- [ ] A2", "- [ ] B" }, inbox_tasks())
	end)

	it("定期タスクでないテンプレートは何もせず、記録もしない", function()
		write_template("manual", { "- [ ] 手で挿入するタスク" })
		assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ "- [ ] 既存のタスク" }, inbox_tasks())
		assert.are.same({}, state.read_recurring())
	end)

	it("無くなった (アーカイブした) テンプレートの記録は消す", function()
		write_template("weekly", { "---", "type: recurring", "repeat: fri", "---", "- [ ] x" })
		state.write_recurring({ weekly = "2026-11-12", archived = "2026-11-01" })
		recurring.create_due_tasks("2026-11-19")
		assert.are.same({ weekly = "2026-11-19" }, state.read_recurring())
	end)

	it("最後の定期タスクが無くなったときも、残った記録を消す", function()
		write_template("manual", { "- [ ] 手で挿入するタスク" })
		state.write_recurring({ archived = "2026-11-01" })
		assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({}, state.read_recurring())
		local saved = vim.json.decode(table.concat(vim.fn.readfile(data_dir .. "/.state.json"), "\n"))
		assert.is_nil(saved.recurring)
	end)

	it(
		".state.json が壊れていれば作らない (記録できないまま作ると、整理のたびに作り直すため)",
		function()
			write_template("weekly", { "---", "type: recurring", "repeat: thu", "---", "- [ ] x" })
			vim.fn.writefile({ "{ broken" }, data_dir .. "/.state.json")
			assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
			assert.are.same({ "- [ ] 既存のタスク" }, inbox_tasks())
			assert.are.same({ "{ broken" }, vim.fn.readfile(data_dir .. "/.state.json"))
			assert.are.equal(1, #notices_with("recurring tasks were not created"))
		end
	)

	it("記録が今日より後なら (時計が戻った)、作らず記録も戻さない", function()
		write_template("weekly", { "---", "type: recurring", "repeat: thu", "---", "- [ ] x" })
		state.write_recurring({ weekly = "2026-11-26" })
		assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ weekly = "2026-11-26" }, state.read_recurring())
	end)

	it("一覧には、定期タスクなら作る日を、読めなければその理由を添える", function()
		local template_mod = require("gtodo-md.ui.template")
		write_template("weekly", { "---", "type: recurring", "repeat: mon, thu", "---", "- [ ] x" })
		write_template("broken", { "---", "type: recurring", "---", "- [ ] x" })
		write_template("manual", { "- [ ] x" })
		assert.are.equal("weekly  (repeat: mon, thu)", template_mod.label("weekly"))
		assert.are.equal("broken  (recurring: a recurring template needs 'repeat:')", template_mod.label("broken"))
		assert.are.equal("manual", template_mod.label("manual"))
	end)

	it("新しいテンプレートの記法メモにある例は、定期タスクとして読まれない", function()
		local template_mod = require("gtodo-md.ui.template")
		assert.is_true(template_mod.ensure_template_file("fresh"))
		local def = logic.read_definition(vim.fn.readfile(data_dir .. "/templates/fresh.md"))
		assert.is_false(def.recurring)
		assert.is_nil(def.error)
		assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
	end)

	it("タスク行の無い定期タスクは知らせ、記録は進める", function()
		write_template("empty", { "---", "type: recurring", "repeat: thu", "---", "<!-- まだ書いていない -->" })
		assert.are.equal(0, recurring.create_due_tasks("2026-11-19"))
		assert.are.same({ empty = "2026-11-19" }, state.read_recurring())
		assert.are.equal(1, #notices_with("empty: no task lines"))
	end)
end)

describe("daily.check_daily_rollover と定期タスク", function()
	local data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/templates", "p")
		for _, k in ipairs({ "gtodo-md.daily", "gtodo-md.lock", "gtodo-md.logic" }) do
			package.loaded[k] = nil
		end
		require("gtodo-md.config").setup({ data_dir = data_dir })
		vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, data_dir .. "/todo.md")
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	it("整理の中で作り、期日が今日のタスクはその場で Today へ移す", function()
		vim.fn.writefile({
			"---",
			"type: recurring",
			"repeat: mon, tue, wed, thu, fri, sat, sun",
			"---",
			"- [ ] 毎日の確認 due:+0d",
		}, data_dir .. "/templates/daily.md")
		local real_notify = vim.notify
		vim.notify = function() end
		local ok = pcall(require("gtodo-md.daily").check_daily_rollover)
		vim.notify = real_notify
		assert.is_true(ok)

		local today = os.date("%Y-%m-%d")
		local todo = vim.tbl_map(strip_id, vim.fn.readfile(data_dir .. "/todo.md"))
		local today_idx = assert(vim.fn.index(todo, "## Today") >= 0 and vim.fn.index(todo, "## Today") + 1)
		local next_idx = vim.fn.index(todo, "## Next") + 1
		local found
		for i = today_idx + 1, next_idx - 1 do
			if todo[i] == "- [ ] 毎日の確認 due:" .. today then
				found = i
			end
		end
		assert.is_not_nil(found, table.concat(todo, "\n"))
		assert.are.same({ daily = today }, require("gtodo-md.state").read_recurring())
	end)
end)
