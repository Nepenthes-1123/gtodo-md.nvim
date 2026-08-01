-- daily.check_daily_rollover が lock.lua 経由の共有ロックで正しく動作することを確認する。

-- serialize が末尾に id:XXXXXX タグをランダム発行して付与するため、
-- 行の完全一致ではなく前方一致(id:タグを除く)で存在確認する。
local function contains_line_prefix(lines, prefix)
	for _, line in ipairs(lines) do
		if line == prefix or line:match("^" .. vim.pesc(prefix) .. " id:%x+$") then
			return true
		end
	end
	return false
end

describe("daily.check_daily_rollover (共有ロック経由)", function()
	local data_dir
	local daily_mod
	local config

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")

		-- モジュールをリロードして daily.lua 内部の永続状態(last_processed_date等)をリセットする
		for _, k in ipairs({ "gtodo-md.daily", "gtodo-md.config", "gtodo-md.lock", "gtodo-md.logic" }) do
			package.loaded[k] = nil
		end
		config = require("gtodo-md.config")
		config.options = { data_dir = data_dir }
		daily_mod = require("gtodo-md.daily")

		vim.fn.writefile({ "# Inbox", "", "- [x] 完了済みinboxタスク" }, data_dir .. "/inbox.md")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [x] 完了済みtodoタスク",
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

	it(
		"last_opened が今日でない場合、完了タスクを done.md へ移動しロックを解放する",
		function()
			daily_mod.check_daily_rollover()

			local today = os.date("%Y-%m-%d")
			local done_lines = vim.fn.readfile(data_dir .. "/done.md")
			assert.is_true(
				contains_line_prefix(done_lines, "- [x] 完了済みinboxタスク done:" .. today .. " from:inbox")
			)
			assert.is_true(
				contains_line_prefix(done_lines, "- [x] 完了済みtodoタスク done:" .. today .. " from:today")
			)

			local inbox_lines = vim.fn.readfile(data_dir .. "/inbox.md")
			assert.is_false(vim.tbl_contains(inbox_lines, "- [x] 完了済みinboxタスク"))

			-- ロックファイルが解放されていること
			assert.are.same(0, vim.fn.filereadable(data_dir .. "/.gtodo.lock"))
		end
	)

	it(
		"既に別インスタンスがロックを保持している場合、ロールオーバーを実行しない",
		function()
			vim.fn.writefile({ "99999" }, data_dir .. "/.gtodo.lock")

			daily_mod.check_daily_rollover()

			-- ロックが取れなかったため、完了タスクは移動されないまま残る
			local inbox_lines = vim.fn.readfile(data_dir .. "/inbox.md")
			assert.is_true(vim.tbl_contains(inbox_lines, "- [x] 完了済みinboxタスク"))
			assert.are.same(0, vim.fn.filereadable(data_dir .. "/done.md"))

			-- 他インスタンスのロックは消さない
			assert.are.same(1, vim.fn.filereadable(data_dir .. "/.gtodo.lock"))

			vim.fn.delete(data_dir .. "/.gtodo.lock")
		end
	)

	-- #98: get_cache() が内部キャッシュテーブルの参照をそのまま返すと、
	-- 呼び出し元が受け取った値を書き換えた際に daily.lua 内部のキャッシュ
	-- そのものが汚染されてしまう。シャローコピーを返すことでこれを防ぐ。
	it("get_cacheは内部キャッシュの参照ではなくコピーを返す(#98)", function()
		daily_mod.check_daily_rollover()

		local mtimes1, _, sizes1 = daily_mod.get_cache()
		mtimes1.todo = 999999999
		sizes1.todo = 999999999

		local mtimes2, _, sizes2 = daily_mod.get_cache()
		assert.are_not.same(
			999999999,
			mtimes2.todo,
			"get_cacheの戻り値を書き換えるとmtimeキャッシュが汚染された"
		)
		assert.are_not.same(
			999999999,
			sizes2.todo,
			"get_cacheの戻り値を書き換えるとsizeキャッシュが汚染された"
		)
	end)

	-- 回帰テスト: reload_if_externally_changed(他インスタンス変更検知用)が
	-- handle_buf_enter 用のキャッシュ(get_cache/update_cache)を巻き込んで
	-- 更新してしまうと、todo.mdが実際に変化していてもhandle_buf_enter側が
	-- 「変化なし」と誤判定してdueチェック・ソートをスキップしてしまう。
	-- 手動テストで発覚: 保存直後にバッファへ入り直しただけでは自動処理が
	-- 走らず、<Leader>to(手動実行、キャッシュ判定を経由しない)でのみ走っていた。
	describe(
		"mtimeキャッシュの分離(他インスタンス変更検知 と handle_buf_enter処理要否判定)",
		function()
			local uv = vim.uv or vim.loop

			it(
				"外部変更検知の実行は、handle_buf_enter用キャッシュ(get_cache)を変化させない",
				function()
					local utils = require("gtodo-md.utils")
					utils.write_last_opened(os.date("%Y-%m-%d"))

					-- 1回目の呼び出しで両キャッシュを初期化させる(同日パス)
					daily_mod.check_daily_rollover()
					local cache_before = daily_mod.get_cache()
					local todo_mtime_before = cache_before.todo

					-- todo.mdのmtimeを変更する(外部からの書き込みを模倣)
					local todo_path = data_dir .. "/todo.md"
					local future = os.time() + 5
					uv.fs_utime(todo_path, future, future)

					-- 2回目の呼び出し: 同日なので reload_if_externally_changed のみが走る
					daily_mod.check_daily_rollover()

					-- 外部変更検知は反応してよいが、handle_buf_enter用キャッシュは
					-- 変化していないはず(handle_buf_enter自身がまだ処理していないため)
					local cache_after = daily_mod.get_cache()
					assert.are.same(
						todo_mtime_before,
						cache_after.todo,
						"外部変更検知がhandle_buf_enter用キャッシュまで更新してしまっている"
					)
				end
			)
		end
	)
end)
