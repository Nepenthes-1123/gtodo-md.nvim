-- conceal_tags: 隠すタグを設定可能にする。
--
-- 位置の特定は task.tag_ranges に委ねる。表示側が自前で正規表現を組むと、
-- 行末アンカーの前提が崩れて黙って失敗する・無差別なマッチで本文を巻き込む、
-- といった不具合を生む(CLAUDE.md の不変条件を参照)。

local task_mod = require("gtodo-md.task")
local config = require("gtodo-md.config")

-- start_col 昇順に並べ、範囲が重なっていないかを見る。
-- 重なると conceal の extmark が重複するため、隣接はしても交差してはならない。
local function sorted_ranges(line)
	local ranges = task_mod.tag_ranges(line)
	table.sort(ranges, function(a, b)
		return a.start_col < b.start_col
	end)
	return ranges
end

local function keys_of(line)
	local names = {}
	for _, r in ipairs(sorted_ranges(line)) do
		table.insert(names, r.key)
	end
	return names
end

-- conceal 後に画面へ残る文字列を再現する。
local function after_conceal(line, tags)
	local hide = {}
	for _, t in ipairs(tags) do
		hide[t] = true
	end
	local out, prev = {}, 0
	for _, r in ipairs(sorted_ranges(line)) do
		if hide[r.key] then
			table.insert(out, line:sub(prev + 1, r.start_col))
			prev = r.end_col
		end
	end
	table.insert(out, line:sub(prev + 1))
	return table.concat(out)
end

describe("task.tag_ranges", function()
	it("key:value 形式のタグの位置を返す", function()
		local line = "- [ ] Task due:2026-09-01 created:2026-08-01 id:a1b2c3"
		for _, r in ipairs(sorted_ranges(line)) do
			local text = line:sub(r.start_col + 1, r.end_col)
			assert.is_truthy(text:find(r.key .. ":", 1, true), "範囲が対象タグを含んでいない: " .. text)
		end
	end)

	-- `+project`/`@context` は key:value 形式ではないため対象外。
	it("+project と @context は返さない", function()
		local names = keys_of("- [ ] Task +proj @home due:2026-09-01 id:a1b2c3")
		assert.is_false(vim.tbl_contains(names, "project"))
		assert.is_false(vim.tbl_contains(names, "context"))
		assert.is_true(vim.tbl_contains(names, "due"))
	end)

	it("タスク行でなければ空を返す", function()
		assert.are.same({}, task_mod.tag_ranges("これはタスク行ではない created:2026-08-01"))
		assert.are.same({}, task_mod.tag_ranges("## Today"))
		assert.are.same({}, task_mod.tag_ranges(""))
	end)

	-- 本文中の `key:` らしき文字列を拾わないこと(picker/split で起きた事故と同種)
	it("URL を key:value として拾わない", function()
		local names = keys_of("- [ ] 資料を読む https://example.com/spec created:2026-08-01")
		assert.are.same({ "created" }, names)
	end)

	it("本文中のコロンを拾わない", function()
		local names = keys_of("- [ ] メモ: 明日やる created:2026-08-01")
		assert.are.same({ "created" }, names)
	end)

	-- 範囲が重なると conceal の extmark が重複する
	it("隣り合うタグの範囲が重ならない", function()
		local lines = {
			"- [ ] Task +proj @home due:2026-09-01 created:2026-08-01 id:a1b2c3",
			"- [x] 完了 completed_at:2026-08-01 done:2026-08-01 from:today id:9f3a21",
			"  - [ ] インデント wait:上司 due:2026-09-01 id:abc123",
		}
		for _, line in ipairs(lines) do
			local ranges = sorted_ranges(line)
			for i = 2, #ranges do
				assert.is_true(
					ranges[i].start_col >= ranges[i - 1].end_col,
					string.format("範囲が重なっている: %s", line)
				)
			end
		end
	end)

	it("インデントされた行でも位置が正しい", function()
		local line = "    - [ ] ネスト created:2026-08-01"
		local r = sorted_ranges(line)[1]
		assert.are.equal("created", r.key)
		assert.is_truthy(line:sub(r.start_col + 1, r.end_col):find("created:2026-08-01", 1, true))
	end)

	it("マルチバイトを含む行でもバイト位置がずれない", function()
		local line = "- [ ] 日本語のタスク内容 wait:上司 id:abc123"
		for _, r in ipairs(sorted_ranges(line)) do
			local text = line:sub(r.start_col + 1, r.end_col)
			assert.is_truthy(text:find(r.key .. ":", 1, true), "位置がずれている: " .. text)
		end
	end)
end)

describe("conceal_tags の設定", function()
	local saved

	before_each(function()
		saved = config.options.conceal_tags
	end)

	after_each(function()
		config.options.conceal_tags = saved
	end)

	it("既定は id のみ(従来の挙動を維持する)", function()
		assert.are.same({ "id" }, config.defaults.conceal_tags)
	end)

	it("既定では id だけが隠れる", function()
		local line = "- [ ] Task created:2026-08-01 id:a1b2c3"
		assert.are.equal("- [ ] Task created:2026-08-01", after_conceal(line, { "id" }))
	end)

	it("created を足すと両方隠れる", function()
		local line = "- [ ] Task created:2026-08-01 id:a1b2c3"
		assert.are.equal("- [ ] Task", after_conceal(line, { "id", "created" }))
	end)

	-- 範囲が後ろの空白を含むため、途中のタグだけ隠しても二重空白にならない
	it("途中のタグだけ隠しても二重空白にならない", function()
		local line = "- [ ] Task due:2026-09-01 created:2026-08-01 id:a1b2c3"
		assert.are.equal("- [ ] Task due:2026-09-01 id:a1b2c3", after_conceal(line, { "created" }))
	end)

	it("+project と @context は隠せない(key:value 限定)", function()
		local line = "- [ ] Task +proj @home id:a1b2c3"
		assert.are.equal("- [ ] Task +proj @home id:a1b2c3", after_conceal(line, { "project", "context" }))
	end)

	-- 未知のタグ名は検証せず、単に一致しないだけ(意図的な仕様)
	it("未知のタグ名を指定しても何も起きない", function()
		local line = "- [ ] Task created:2026-08-01 id:a1b2c3"
		assert.are.equal(line, after_conceal(line, { "creted", "nonexistent" }))
	end)

	it("空リストなら何も隠れない", function()
		local line = "- [ ] Task created:2026-08-01 id:a1b2c3"
		assert.are.equal(line, after_conceal(line, {}))
	end)
end)
