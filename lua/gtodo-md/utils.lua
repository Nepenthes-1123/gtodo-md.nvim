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

function M.parse_due_date(str)
	if not str or str == "" then
		return nil
	end
	str = vim.trim(str):lower()

	local today = os.time()

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

local function get_state_path()
	local config = require("gtodo-md.config")
	local data_dir = config.get("data_dir")
	return data_dir .. "/.state.json"
end

local function read_state()
	local path = get_state_path()
	local f = io.open(path, "r")
	if not f then
		return {}
	end
	local content = f:read("*all")
	f:close()
	if not content or content == "" then
		return {}
	end
	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function write_state(data)
	local path = get_state_path()
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		-- mkdir() は失敗時に 0 を返すほか、パス上に同名のファイルがある等では
		-- E739 を投げる。素通しにすると `setup()` の途中で例外が飛び、プラグイン全体の
		-- 初期化がそこで止まる(しかもユーザーには原因が読み取れない)。
		local ok, created = pcall(vim.fn.mkdir, dir, "p")
		if not ok or created == 0 then
			vim.notify(string.format("[gtodo-md] failed to create data directory: %s", dir), vim.log.levels.ERROR)
			return
		end
	end
	local ok, content = pcall(vim.json.encode, data)
	if not ok then
		-- 握り潰すと .state.json への永続化が黙ってスキップされ、
		-- 「設定したはずの内容が次回起動時に消えている」形で表面化する。
		-- すぐ下の atomic_write 失敗と同じく通知する。
		vim.notify(string.format("[gtodo-md] failed to encode %s: %s", path, tostring(content)), vim.log.levels.ERROR)
		return
	end
	-- config.lua がこのモジュールを require するため、io.lua はここで遅延requireする
	-- (io.lua は config.lua を require しており、トップレベルで書くと循環参照になる)。
	local io_mod = require("gtodo-md.io")
	local written, err = io_mod.atomic_write(path, content)
	if not written then
		vim.notify(string.format("[gtodo-md] failed to write %s: %s", path, err), vim.log.levels.ERROR)
	end
end

function M.read_last_opened()
	local state = read_state()
	return state.last_opened
end

function M.write_last_opened(date_str)
	local state = read_state()
	state.last_opened = date_str
	write_state(state)
end

-- #94: 前回の setup() で使われていたセクション名(config.sections)を記憶する。
-- ユーザーがカスタム名を変更・削除した直後は、ファイル側の見出しがまだ
-- 前回の名前のままであることが多いため、config.section_aliases がこれも
-- 一時的にエイリアスとして受理することで、設定変更直後の保存がブロック
-- されず、次回保存時に新しい名前へ自動的に移行できるようにする
-- (全履歴ではなく直前の1世代分のみを覚える)。
function M.read_last_sections()
	local state = read_state()
	return state.last_sections
end

function M.write_last_sections(sections)
	local state = read_state()
	state.last_sections = sections
	write_state(state)
end

function M.read_notify_state()
	local state = read_state()
	return state.last_notify_time or 0, state.last_notify_content or ""
end

function M.write_notify_state(time, content)
	local state = read_state()
	state.last_notify_time = time
	state.last_notify_content = content
	write_state(state)
end

function M.create_project_file(project_tag)
	local data_dir = require("gtodo-md.config").options.data_dir
	local projects_dir = data_dir .. "/projects"

	if vim.fn.isdirectory(projects_dir) == 0 then
		-- write_state と同じ理由で pcall する(失敗時 0、パス上にファイルがあれば E739)。
		local ok, created = pcall(vim.fn.mkdir, projects_dir, "p")
		if not ok or created == 0 then
			vim.notify(
				string.format("[gtodo-md] failed to create projects directory: %s", projects_dir),
				vim.log.levels.ERROR
			)
			return false
		end
	end

	local proj_file = string.format("%s/%s.md", projects_dir, project_tag)
	if vim.fn.filereadable(proj_file) == 0 then
		local today = os.date("%Y-%m-%d")
		local template = {
			"---",
			"title:",
			"tag: " .. project_tag,
			"created: " .. today,
			"due:",
			"status: active",
			"members: []",
			"---",
			"",
			"## Overview",
			"",
			"## Notes",
			"",
			"## Reference",
			"",
		}

		-- 循環参照を避けるためここで遅延requireする(write_state と同じ理由)。
		local io_mod = require("gtodo-md.io")
		local written, err = io_mod.atomic_write(proj_file, table.concat(template, "\n") .. "\n")
		if not written then
			vim.notify(string.format("Failed to create project file: %s (%s)", proj_file, err), vim.log.levels.ERROR)
			return false
		end
		vim.notify("Created new project file: " .. project_tag, vim.log.levels.INFO)
		return true
	end
	return true
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
