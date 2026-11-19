-- 定期タスクの定義 (テンプレートのフロントマター) の読み取りと、「その日に作るか」の判定。
--
-- ファイルにも vim.api にも触れない純関数だけを置く。日付は "YYYY-MM-DD" の文字列で受け渡し、
-- 計算は os.time を使わず暦から日数を出して行う (時刻・タイムゾーン・夏時間に左右されないように)。
-- gtodo (CLI) はこれらの結果をゴールデンテストで固定して同じ規則を持つため、規則を変えるときは
-- CLI の移植も合わせて変えること。作る処理 (テンプレートを読み、inbox.md へ足し、記録する) は
-- recurring.lua にある。
--
-- フロントマターの書き方:
--   ---
--   type: recurring
--   repeat: mon, thu, 15, end, 2nd tue, last fri, 04-01
--   values:
--     project: site
--   ---
-- repeat の項目はどれか 1 つに当たる日に作る (和集合)。大文字小文字は区別しない。
local M = {}

local WEEKDAYS = { sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6 }
local ORDINALS = { ["1st"] = 1, ["2nd"] = 2, ["3rd"] = 3, ["4th"] = 4, last = -1 }

-- 何も作られなかった期間をさかのぼって探す上限。どの規則も 1 年 (366 日) の間に必ず 1 度は当たる
-- (毎年の 02-29 も、閏年でない年は 2/28 に当たる) ので、それより前を見ても最後の回は変わらない。
local LOOKBACK_DAYS = 366

local function is_leap(y)
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function days_in_month(y, m)
	if m == 2 then
		return is_leap(y) and 29 or 28
	end
	if m == 4 or m == 6 or m == 9 or m == 11 then
		return 30
	end
	return 31
end

-- 1970-01-01 からの日数 (Howard Hinnant の days_from_civil)。
local function to_days(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function from_days(z)
	z = z + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	if m <= 2 then
		y = y + 1
	end
	return y, m, d
end

-- 曜日 (日曜が 0)。1970-01-01 は木曜。
local function weekday(z)
	return (z + 4) % 7
end

-- "YYYY-MM-DD" を日数にする。実在しない日付なら nil。
local function parse_date(str)
	if type(str) ~= "string" then
		return nil
	end
	local y, m, d = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then
		return nil
	end
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	if m < 1 or m > 12 or d < 1 or d > days_in_month(y, m) then
		return nil
	end
	return to_days(y, m, d)
end

local function format_date(z)
	local y, m, d = from_days(z)
	return string.format("%04d-%02d-%02d", y, m, d)
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 値を囲む引用符 ("..." / '...') を外す (YAML で書く人のため。エスケープは解釈しない)。
local function unquote(v)
	local inner = v:match('^"(.*)"$') or v:match("^'(.*)'$")
	return inner or v
end

-- repeat の 1 項目を規則にする。読めなければ nil。
local function parse_item(item)
	local text = item:lower()
	if WEEKDAYS[text] then
		return { kind = "weekday", weekday = WEEKDAYS[text] }
	end
	if text == "end" then
		return { kind = "month_end" }
	end
	local n = text:match("^(%d%d?)$")
	if n then
		n = tonumber(n)
		if n >= 1 and n <= 31 then
			return { kind = "month_day", day = n }
		end
		return nil
	end
	local ord, wd = text:match("^(%S+)%s+(%a+)$")
	if ord and ORDINALS[ord] and WEEKDAYS[wd] then
		return { kind = "nth_weekday", nth = ORDINALS[ord], weekday = WEEKDAYS[wd] }
	end
	local mm, dd = text:match("^(%d%d?)%-(%d%d?)$")
	if mm then
		mm, dd = tonumber(mm), tonumber(dd)
		-- 閏年にある日 (02-29) までは受け付ける。その月に無い日 (04-31 など) は書き間違いとみなす。
		if mm >= 1 and mm <= 12 and dd >= 1 and dd <= days_in_month(2000, mm) then
			return { kind = "year_day", month = mm, day = dd }
		end
	end
	return nil
end

-- repeat の値を規則のリストにする。読めない項目があれば nil とエラーの文言。
function M.parse_repeat(spec)
	if type(spec) ~= "string" or trim(spec) == "" then
		return nil, "repeat is empty"
	end
	local rules = {}
	for item in (spec .. ","):gmatch("([^,]*),") do
		local text = trim(item)
		if text == "" then
			return nil, string.format("repeat %q has an empty item", spec)
		end
		local rule = parse_item(text)
		if not rule then
			return nil,
				string.format(
					"repeat: %q is not a day (use mon..sun, 1..31, end, 1st..4th/last + a weekday, or MM-DD)",
					text
				)
		end
		table.insert(rules, rule)
	end
	return rules
end

-- 先頭の行が `---` で、閉じる `---` があるときだけフロントマターとして読む (閉じていなければ無いものとする)。
-- 返り値: { fields = { key = value }, values = { name = value } } (無ければ nil) と、本文の最初の行番号。
-- `key: value` の key は行頭から書く。`values:` (値なし) の後の字下げした行が values になる。
-- 空行と `#` で始まる行は読み飛ばす。知らないキーは読むだけで使わない。
function M.parse_frontmatter(lines)
	local first = lines[1] and lines[1]:gsub("\r$", "")
	if not first or trim(first) ~= "---" then
		return nil, 1
	end
	local close
	for i = 2, #lines do
		if trim((lines[i]:gsub("\r$", ""))) == "---" then
			close = i
			break
		end
	end
	if not close then
		return nil, 1
	end
	local fields, values = {}, {}
	local in_values = false
	for i = 2, close - 1 do
		local line = lines[i]:gsub("\r$", "")
		-- 空行と `#` のコメントは読み飛ばす(values: の続きも切らない)。
		local skip = line:match("^%s*$") or line:match("^%s*#")
		if not skip and line:match("^%s") then
			if in_values then
				local k, v = line:match("^%s+([%w_]+)%s*:%s*(.-)%s*$")
				if k then
					values[k] = unquote(v)
				end
			end
		elseif not skip then
			local k, v = line:match("^([%w_]+)%s*:%s*(.-)%s*$")
			if k then
				fields[k] = unquote(v)
				in_values = k == "values" and v == ""
			else
				in_values = false
			end
		end
	end
	return { fields = fields, values = values }, close + 1
end

-- テンプレートの行から定義を読む。
-- 返り値: {
--   recurring = 定期タスクか,
--   rules = 規則のリスト (定期タスクのとき),
--   repeat_text = repeat に書かれた値,
--   values = values: に書かれた値 (定期タスクでなくても、手で挿入するときの初期値に使う),
--   body = フロントマターの後の行,
--   error = 定期タスクとして読めない理由 (読めれば nil),
-- }
function M.read_definition(lines)
	local fm, body_start = M.parse_frontmatter(lines)
	local def = {
		recurring = false,
		rules = nil,
		repeat_text = nil,
		values = fm and fm.values or {},
		body = {},
		error = nil,
	}
	for i = body_start, #lines do
		table.insert(def.body, lines[i])
	end
	if not fm then
		return def
	end
	local kind = fm.fields.type
	def.repeat_text = fm.fields["repeat"]
	if kind == nil or kind == "" then
		if def.repeat_text and def.repeat_text ~= "" then
			def.error = "repeat needs 'type: recurring'"
		end
		return def
	end
	if kind ~= "recurring" then
		def.error = string.format("unknown type %q (only 'recurring' is supported)", kind)
		return def
	end
	def.recurring = true
	if not def.repeat_text or def.repeat_text == "" then
		def.error = "a recurring template needs 'repeat:'"
		return def
	end
	local rules, err = M.parse_repeat(def.repeat_text)
	if not rules then
		def.error = err
		return def
	end
	def.rules = rules
	return def
end

local function occurs_on_days(rules, z)
	local y, m, d = from_days(z)
	local wd = weekday(z)
	local last = days_in_month(y, m)
	for _, r in ipairs(rules) do
		if r.kind == "weekday" then
			if wd == r.weekday then
				return true
			end
		elseif r.kind == "month_day" then
			-- その月に無い日 (11 月の 31 など) は月末に作る。
			if d == r.day or (r.day > last and d == last) then
				return true
			end
		elseif r.kind == "month_end" then
			if d == last then
				return true
			end
		elseif r.kind == "nth_weekday" then
			if wd == r.weekday then
				if r.nth == -1 then
					if d + 7 > last then
						return true
					end
				elseif math.floor((d - 1) / 7) + 1 == r.nth then
					return true
				end
			end
		elseif r.kind == "year_day" then
			if m == r.month and (d == r.day or (r.day > last and d == last)) then
				return true
			end
		end
	end
	return false
end

-- date ("YYYY-MM-DD") が規則のどれかに当たるか。
function M.occurs_on(rules, date)
	local z = parse_date(date)
	return z ~= nil and occurs_on_days(rules, z)
end

-- after (これより後。nil なら today の前日) から today までに当たる日のうち、最後の日を返す。無ければ nil。
-- after が nil なのは、まだ一度も確かめていないテンプレート (作ったばかり・復元したばかり)。
-- 過去の回をさかのぼって作らないよう、today の分だけを見る。
function M.latest_occurrence(rules, after, today)
	local t = parse_date(today)
	if not t then
		return nil
	end
	local lower = after and parse_date(after) or (t - 1)
	if not lower then
		lower = t - 1
	end
	local stop = math.max(lower + 1, t - LOOKBACK_DAYS + 1)
	for z = t, stop, -1 do
		if occurs_on_days(rules, z) then
			return format_date(z)
		end
	end
	return nil
end

-- from ("YYYY-MM-DD") より後で、最初に当たる日 (一覧に「次に作る日」として出す)。
function M.next_occurrence(rules, from)
	local f = parse_date(from)
	if not f then
		return nil
	end
	for z = f + 1, f + LOOKBACK_DAYS do
		if occurs_on_days(rules, z) then
			return format_date(z)
		end
	end
	return nil
end

-- テスト用。
M._parse_date = parse_date
M._format_date = format_date

return M
