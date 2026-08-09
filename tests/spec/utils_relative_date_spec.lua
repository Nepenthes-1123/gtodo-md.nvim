-- #88 回帰テスト: 相対日付 +Nm / +Ny が固定日数(30日/365日)ではなく、
-- 暦算(「翌月/翌年の同日」)で計算されることを確認する。
-- 対象月に存在しない日(月末超過・閏日)は月末へクランプする仕様とする
-- (例: 1/31 + 1ヶ月 → 3月にはならず、2月の末日になる)。

local utils = require("gtodo-md.utils")

-- os.time() を引数無しで呼んだ場合にだけ固定の日時を返すようにする。
-- テーブルを渡す呼び出し(add_months/days_in_monthの内部計算)は本物の
-- os.time にそのまま委譲するため、暦計算そのものはモックしていない。
local function with_fixed_now(y, m, d, hh, fn)
	local original_time = os.time
	os.time = function(t) -- luacheck: ignore
		if t then
			return original_time(t)
		end
		return original_time({ year = y, month = m, day = d, hour = hh or 12 })
	end
	local ok, err = pcall(fn)
	os.time = original_time -- luacheck: ignore
	if not ok then
		error(err, 0)
	end
end

describe("utils.parse_due_date 相対日付 +Nm/+Ny の暦算 (#88)", function()
	it("+1m: 通常の月はそのまま同日の翌月になる", function()
		with_fixed_now(2024, 1, 15, 12, function()
			assert.are.same("2024-02-15", utils.parse_due_date("+1m"))
		end)
	end)

	it(
		"+1m: 月末超過は非閏年2月の末日(28日)へクランプされる(3月へ繰り越さない)",
		function()
			with_fixed_now(2023, 1, 31, 12, function()
				assert.are.same("2023-02-28", utils.parse_due_date("+1m"))
			end)
		end
	)

	it("+1m: 月末超過は閏年2月の末日(29日)へクランプされる", function()
		with_fixed_now(2024, 1, 31, 12, function()
			assert.are.same("2024-02-29", utils.parse_due_date("+1m"))
		end)
	end)

	it("+1m: 12月から1月への年またぎが正しく計算される", function()
		with_fixed_now(2023, 12, 15, 12, function()
			assert.are.same("2024-01-15", utils.parse_due_date("+1m"))
		end)
	end)

	it("+2m: 複数月かつ年またぎでも正しく計算される", function()
		with_fixed_now(2023, 11, 30, 12, function()
			assert.are.same("2024-01-30", utils.parse_due_date("+2m"))
		end)
	end)

	it("+1y: 通常の日付はそのまま同日の翌年になる", function()
		with_fixed_now(2024, 3, 10, 12, function()
			assert.are.same("2025-03-10", utils.parse_due_date("+1y"))
		end)
	end)

	it("+1y: 閏日(2/29)は翌年が非閏年ならその年の2月末日(28日)へクランプされる", function()
		with_fixed_now(2024, 2, 29, 12, function()
			assert.are.same("2025-02-28", utils.parse_due_date("+1y"))
		end)
	end)

	it("+Nd/+Nw は従来通り固定日数のまま", function()
		with_fixed_now(2024, 1, 31, 12, function()
			assert.are.same("2024-02-05", utils.parse_due_date("+5d"))
			assert.are.same("2024-02-07", utils.parse_due_date("+1w"))
		end)
	end)
end)

-- タスクテンプレート機能(ui/template.lua)は「挿入時点の実日付」ではなく
-- 「ユーザーが指定した基準日」から相対指定を解決したいため、第2引数で
-- 基準日時を明示的に注入できるようにする。省略時は従来通り os.time()(実際の今)。
describe("utils.parse_due_date 第2引数(base_time)による基準日の明示指定", function()
	it(
		"base_time を渡すと、相対指定はos.time()(実際の今)ではなくbase_time基準で解決される",
		function()
			local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
			assert.are.same("2024-01-13", utils.parse_due_date("+3d", base_time))
			assert.are.same("2024-01-17", utils.parse_due_date("+1w", base_time))
		end
	)

	it("base_time を渡しても today/tomorrow はその基準日を指す", function()
		local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
		assert.are.same("2024-01-10", utils.parse_due_date("today", base_time))
		assert.are.same("2024-01-11", utils.parse_due_date("tomorrow", base_time))
	end)

	it("絶対日付(YYYY-MM-DD)は base_time の値に関わらず変化しない", function()
		local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
		assert.are.same("2026-08-20", utils.parse_due_date("2026-08-20", base_time))
	end)

	it("base_time を省略した場合は従来通り os.time()(実際の今)が使われる", function()
		with_fixed_now(2024, 5, 1, 12, function()
			assert.are.same("2024-05-04", utils.parse_due_date("+3d"))
		end)
	end)
end)
