-- api.get_stats() が副作用(日次ロールオーバー)を持たないこと、および
-- daily.check_daily_rollover() が「実際にロールオーバーしたか」を返すことを確認する。
--
-- get_stats() は statusline の再描画のたびに呼ばれるため、その中で
-- ファイル書き込み・排他ロック取得・バッファリロードを行ってはならない。
-- ロールオーバーの契機は timer.lua の60秒タイマーと autocmd 側が担う。

describe("api.get_stats の副作用除去と check_daily_rollover の戻り値", function()
	local data_dir
	local api_mod
	local daily_mod
	local config

	local function reload_modules()
		for _, k in ipairs({
			"gtodo-md.api",
			"gtodo-md.daily",
			"gtodo-md.config",
			"gtodo-md.lock",
			"gtodo-md.logic",
		}) do
			package.loaded[k] = nil
		end
		config = require("gtodo-md.config")
		config.options = { data_dir = data_dir }
		api_mod = require("gtodo-md.api")
		daily_mod = require("gtodo-md.daily")
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")

		-- モジュールをリロードして内部の永続状態(last_processed_date/mtimeキャッシュ)をリセットする
		reload_modules()

		vim.fn.writefile(
			{ "# Inbox", "", "- [x] 完了済みinboxタスク", "- [ ] 未完了inboxタスク" },
			data_dir .. "/inbox.md"
		)
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [x] 完了済みtodoタスク",
			"- [ ] 未完了todoタスク",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, data_dir .. "/todo.md")

		-- ロールオーバー対象となるよう last_opened を過去日にしておく
		require("gtodo-md.state").write_last_opened("2000-01-01")
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	it("get_stats は last_opened が過去日でもロールオーバーを実行しない", function()
		local stats = api_mod.get_stats()

		-- 副作用がなければ done.md は作られず、完了タスクも元のファイルに残ったまま
		assert.are.same(0, vim.fn.filereadable(data_dir .. "/done.md"), "get_stats が done.md を作成した")

		local inbox_lines = vim.fn.readfile(data_dir .. "/inbox.md")
		assert.is_true(
			vim.tbl_contains(inbox_lines, "- [x] 完了済みinboxタスク"),
			"get_stats が inbox.md を書き換えた"
		)

		-- last_opened も進んでいないこと
		assert.are.same("2000-01-01", require("gtodo-md.state").read_last_opened())

		-- 件数のカウント自体は従来どおり動作する
		assert.are.same(1, stats.today)
		assert.are.same(1, stats.inbox)
	end)

	it("check_daily_rollover は実行時に true、同日2回目は false を返す", function()
		assert.is_true(daily_mod.check_daily_rollover(), "日付変更ありの初回は true を返すべき")
		assert.is_false(daily_mod.check_daily_rollover(), "同日2回目は false を返すべき")
	end)

	it("check_daily_rollover はロックを取得できない場合 false を返す", function()
		vim.fn.writefile({ "99999" }, data_dir .. "/.gtodo.lock")

		assert.is_false(daily_mod.check_daily_rollover())

		vim.fn.delete(data_dir .. "/.gtodo.lock")
	end)

	it("check_daily_rollover は last_opened が今日なら false を返す", function()
		require("gtodo-md.state").write_last_opened(os.date("%Y-%m-%d"))

		assert.is_false(daily_mod.check_daily_rollover())
	end)
end)
