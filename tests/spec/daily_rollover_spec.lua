-- daily.check_daily_rollover が lock.lua 経由の共有ロックで正しく動作することを確認する。

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
				vim.tbl_contains(done_lines, "- [x] 完了済みinboxタスク done:" .. today .. " from:inbox")
			)
			assert.is_true(
				vim.tbl_contains(done_lines, "- [x] 完了済みtodoタスク done:" .. today .. " from:today")
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
end)
