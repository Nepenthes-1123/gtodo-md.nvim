local M = {}

-- 指定した年月の末日を返す(#88: 月末クランプ計算用)。
-- 翌月1日の前日 = 当月末日、というトリックで求める。month=13等の
-- 範囲外の値は os.time が年へ繰り上げて正規化するため year をまたいでも正しい。
-- DST境界での日付ズレを避けるため hour=12(正午)を基準にする。
local function days_in_month(year, month)
	local t = os.time({ year = year, month = month + 1, day = 0, hour = 12 })
	return tonumber(os.date("%d", t))
end

-- year/month/day に月単位の差分を加算する(#88: 暦算・月末クランプ)。
-- 対象月に存在しない日(例: 1/31 + 1ヶ月 → 2月31日)は、その月の末日に
-- クランプする(繰り越して3月にはしない)。+1y は +12m として扱う。
local function add_months(year, month, day, delta_months)
	local total_months = year * 12 + (month - 1) + delta_months
	local new_year = math.floor(total_months / 12)
	local new_month = (total_months % 12) + 1
	local new_day = math.min(day, days_in_month(new_year, new_month))
	return new_year, new_month, new_day
end

-- 日付文字列 (YYYY-MM-DD) → os.time に変換する
function M.date_to_time(date_str)
	return os.time({
		year = tonumber(date_str:sub(1, 4)),
		month = tonumber(date_str:sub(6, 7)),
		day = tonumber(date_str:sub(9, 10)),
		hour = 0,
		min = 0,
		sec = 0,
	})
end

-- base_time(epoch秒)を省略した場合は従来通り os.time()(実際の今)を基準にする。
-- テンプレート機能(ui/template.lua)が「挿入時点の実日付」ではなく
-- 「ユーザーが指定した基準日」から相対指定を解決するために利用する。
function M.parse_due_date(str, base_time)
	if not str or str == "" then
		return nil
	end
	str = vim.trim(str):lower()

	local today = base_time or os.time()

	-- today, tomorrow, etc.
	if str == "today" or str == "t" then
		return os.date("%Y-%m-%d", today)
	elseif str == "tomorrow" or str == "tm" then
		return os.date("%Y-%m-%d", today + 24 * 3600)
	end

	-- relative: +Nd, +Nw, +Nm, +Ny
	local num, unit = str:match("^%+(%d+)([dwmy]?)$")
	if num then
		num = tonumber(num)
		if unit == "" or unit == "d" then
			return os.date("%Y-%m-%d", today + num * 24 * 3600)
		elseif unit == "w" then
			return os.date("%Y-%m-%d", today + num * 7 * 24 * 3600)
		elseif unit == "m" or unit == "y" then
			-- #88: 固定日数(30日/365日)ではなく暦算で「翌月/翌年の同日」を求める。
			-- 存在しない日(月末超過・閏日等)は月末クランプする(add_months参照)。
			local t = os.date("*t", today)
			local delta_months = (unit == "y") and (num * 12) or num
			local ny, nm, nd = add_months(t.year, t.month, t.day, delta_months)
			return string.format("%04d-%02d-%02d", ny, nm, nd)
		end
	end

	-- Day of week: mon, tue, wed, thu, fri, sat, sun
	local wdays = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 }
	local wday_num = wdays[str:sub(1, 3)]
	if wday_num then
		local current_wday = tonumber(os.date("%w", today)) + 1 -- 1: Sun, 7: Sat
		local diff = wday_num - current_wday
		if diff <= 0 then
			diff = diff + 7
		end -- next week
		return os.date("%Y-%m-%d", today + diff * 24 * 3600)
	end

	-- YYYY-MM-DD, YYYY/MM/DD, YYYYMMDD
	local y, m, d = str:match("^(%d%d%d%d)[%-/](%d%d?)[%-/](%d%d?)$")
	if not y then
		y, m, d = str:match("^(%d%d%d%d)(%d%d)(%d%d)$")
	end

	-- MM-DD, MM/DD
	if not y then
		m, d = str:match("^(%d%d?)[%-/](%d%d?)$")
		if m then
			y = os.date("%Y", today)
		end
	end

	if y and m and d then
		return string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
	end

	if str:match("^%d%d%d%d%-%d%d%-%d%d$") then
		return str
	end

	return nil
end

-- 指定ディレクトリが無ければ再帰的に作成する。mkdir()は失敗時に0を返すほか、
-- パス上に同名のファイルがある等ではE739を投げるため、pcallで包んで真偽値として返す。
-- 通知メッセージは呼び出し元ごとに文言が異なるため、ここでは行わない(呼び出し元の責務)。
function M.ensure_dir(path)
	if vim.fn.isdirectory(path) == 1 then
		return true
	end
	local ok, created = pcall(vim.fn.mkdir, path, "p")
	return ok and created ~= 0
end

function M.is_gtodo_file(bufname)
	if not bufname or bufname == "" then
		return false
	end
	local config = require("gtodo-md.config")
	local data_dir = config.get("data_dir")
	if not data_dir or data_dir == "" then
		return false
	end

	-- 相対パス・ドットパスを絶対パスへ正規化
	local abs_bufname = vim.fn.fnamemodify(bufname, ":p")
	local abs_datadir = vim.fn.fnamemodify(data_dir, ":p")

	local norm_bufname = abs_bufname:gsub("\\", "/"):lower()
	local norm_datadir = abs_datadir:gsub("\\", "/"):lower()

	if norm_datadir:sub(-1) ~= "/" then
		norm_datadir = norm_datadir .. "/"
	end

	if norm_bufname:sub(1, #norm_datadir) == norm_datadir then
		local rel = norm_bufname:sub(#norm_datadir + 1)
		if rel == "inbox.md" or rel == "todo.md" or rel == "done.md" or rel == "cancelled.md" then
			return true
		end
		if rel:match("^projects/[^/]+%.md$") then
			return true
		end
	end
	return false
end

return M
