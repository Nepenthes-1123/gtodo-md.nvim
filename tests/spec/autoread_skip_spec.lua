local timer, utils
local worktree = vim.fn.getcwd():gsub("\\", "/")

describe("autoread and timer skip for project files", function()
	before_each(function()
		-- daily/logic/lock/io は永続状態(キャッシュされたmtime、書き込み前の世代スタンプ等)を
		-- 持つため、テスト間の汚染を避けて毎回リロードする。
		--
		-- **一部だけを列挙してリロードしてはいけない。** 例えば io だけを差し替えると、
		-- 先に読み込まれた logic/sort.lua が上位値として掴んでいる古い io と、
		-- autocmd が require で取り直す新しい io が別インスタンスになり、
		-- モジュールローカルの状態(世代スタンプ表)が分裂する。
		-- 本番ではモジュールは一度しか読まれないため起きない、テスト固有の事故である。
		for name, _ in pairs(package.loaded) do
			if name == "gtodo-md" or name:match("^gtodo%-md%.") then
				package.loaded[name] = nil
			end
		end
		utils = require("gtodo-md.utils")
		timer = require("gtodo-md.timer")

		local config = require("gtodo-md.config")
		config.setup({ data_dir = worktree })

		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
	end)

	-- R1-4: 未保存(dirty)バッファの有無は自動処理の実行可否に影響しなくなった。
	-- should_skip_timer は現在ノーマルモードかどうかのみを見る。
	it(
		"should_skip_timer はノーマルモードでは false を返す(未保存バッファがあっても)",
		function()
			local buf = vim.api.nvim_create_buf(true, false)
			local proj_path = worktree .. "/projects/test_proj_modified.md"
			vim.api.nvim_buf_set_name(buf, proj_path)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "title: Test", "---" })
			vim.bo[buf].modified = true

			assert.is_false(timer.should_skip_timer())

			vim.api.nvim_buf_delete(buf, { force = true })
		end
	)

	it("should_skip_timer はノーマルモード以外では true を返す", function()
		-- headlessでは startinsert が同期的にモードへ反映されないため、
		-- vim.fn.mode を直接差し替えて検証する
		local original_mode = vim.fn.mode
		vim.fn.mode = function()
			return "i"
		end
		local ok, result = pcall(timer.should_skip_timer)
		vim.fn.mode = original_mode

		assert.is_true(ok)
		assert.is_true(result)
	end)

	it("sets autoread option on inbox.md buffer in data_dir via autocmd", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = vim.fn.getcwd() })
		require("gtodo-md").setup_autocmds()

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/inbox.md")

		vim.api.nvim_exec_autocmds("BufEnter", { group = "GtodoMd", buffer = buf })

		assert.is_true(vim.bo[buf].autoread)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("sets autoread option on projects/*.md buffer in data_dir via autocmd", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = vim.fn.getcwd() })
		require("gtodo-md").setup_autocmds()

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/projects/my_project.md")

		vim.api.nvim_exec_autocmds("BufEnter", { group = "GtodoMd", buffer = buf })

		assert.is_true(vim.bo[buf].autoread)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("utils.is_gtodo_file correctly identifies gtodo files and excludes external files", function()
		local config = require("gtodo-md.config")
		config.setup({ data_dir = "C:/my_gtodo_data" })

		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/inbox.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/todo.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/done.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/cancelled.md"))
		assert.is_true(utils.is_gtodo_file("C:/my_gtodo_data/projects/my_project.md"))

		-- 相対パスでも正しく判定できること
		config.setup({ data_dir = vim.fn.getcwd() })
		assert.is_true(utils.is_gtodo_file("inbox.md"))
		assert.is_true(utils.is_gtodo_file("projects/my_proj_modified.md"))

		-- 隣接名ディレクトリや外部プロジェクトの拒否
		assert.is_false(utils.is_gtodo_file("C:/my_gtodo_data_backup/inbox.md"))
		assert.is_false(utils.is_gtodo_file("C:/external/projects/my_project.md"))
		assert.is_false(utils.is_gtodo_file("C:/my_gtodo_data/readme.md"))
		assert.is_false(utils.is_gtodo_file(""))
		assert.is_false(utils.is_gtodo_file(nil))
	end)

	-- R1-2/R1-4 回帰テスト: 以前は未保存(dirty)なバッファがあると
	-- handle_buf_enter は自動処理を丸ごとスキップしていたが、現在は
	-- dirty かどうかに関わらず常に処理・保存し、未保存編集も失わない。
	it("handle_buf_enter は未保存(dirty)なバッファでも自動処理を実行し保存する", function()
		local main_mod = require("gtodo-md")
		local config = require("gtodo-md.config")
		local state_mod = require("gtodo-md.state")

		local data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })

		-- 日次ロールオーバー分岐に入らないよう、既に今日処理済みとしておく
		state_mod.write_last_opened(os.date("%Y-%m-%d"))

		vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 既存タスク",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, data_dir .. "/todo.md")

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, data_dir .. "/todo.md")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 既存タスク",
			"- [ ] 手動で追加した未保存タスク",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		})
		vim.bo[buf].modified = true

		main_mod.handle_buf_enter(buf)

		-- dirtyでも常に処理・保存されるため、未保存状態は解消される
		assert.is_false(vim.bo[buf].modified)
		-- 手動で追加した未保存分の内容は失われていない
		-- (sort_todo_file がファイル全体を書き戻す際、serializeが末尾に
		-- id:XXXXXX タグを新規発行するため前方一致で確認する)
		local after_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local found = false
		for _, line in ipairs(after_lines) do
			if line:match("^%- %[ %] 手動で追加した未保存タスク%s*") then
				found = true
				break
			end
		end
		assert.is_true(found, "手動タスクの行が見当たらない: " .. vim.inspect(after_lines))

		vim.api.nvim_buf_delete(buf, { force = true })
		vim.fn.delete(data_dir, "rf")
	end)

	-- 回帰テスト: 保存直後(クリーンな状態)にバッファへ入り直しても、
	-- check_daily_rollover が先に外部変更検知用キャッシュを消費してしまい
	-- handle_buf_enter 自身の dueチェック・ソートがスキップされていた不具合。
	-- 手動テストで発覚(このsame-day経路を経由すると自動処理が実行されず、
	-- <Leader>to のような無条件実行のコマンドでしか動かなかった)。
	it(
		"保存直後にクリーンなバッファへ入り直しても、dueチェック・ソートが実行される",
		function()
			local main_mod = require("gtodo-md")
			local config = require("gtodo-md.config")
			local state_mod = require("gtodo-md.state")
			local daily_mod = require("gtodo-md.daily")
			local uv = vim.uv or vim.loop

			local data_dir = vim.fn.tempname()
			vim.fn.mkdir(data_dir .. "/projects", "p")
			config.setup({ data_dir = data_dir })
			state_mod.write_last_opened(os.date("%Y-%m-%d"))

			local todo_path = data_dir .. "/todo.md"
			vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
			vim.fn.writefile({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 既存タスク",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}, todo_path)

			-- プラグイン起動時相当の呼び出し(M.setupが行うのと同じ)で
			-- 両キャッシュを初期化しておく
			daily_mod.check_daily_rollover()

			-- ユーザーが手打ちでタスクを追加して :w で保存した状態を模倣する
			-- (バッファは無く、ディスクへ直接書き込み、mtimeを未来にずらして変化させる)
			vim.fn.writefile({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 既存タスク",
				"- [ ] 手打ちタスク",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}, todo_path)
			local future = os.time() + 5
			uv.fs_utime(todo_path, future, future)

			-- 保存直後、クリーンなバッファでtodo.mdに入り直す
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, todo_path)
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("edit!")
			end)
			assert.is_false(vim.bo[buf].modified)

			main_mod.handle_buf_enter(buf)

			-- dueチェック・ソートが実際に走っていれば、手打ちタスクにIDが付与される
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local found = false
			for _, line in ipairs(lines) do
				if line:match("^%- %[ %] 手打ちタスク id:%x+$") then
					found = true
					break
				end
			end
			assert.is_true(
				found,
				"手打ちタスクにIDが付与されていない(自動処理がスキップされた): "
					.. vim.inspect(lines)
			)

			vim.api.nvim_buf_delete(buf, { force = true })
			vim.fn.delete(data_dir, "rf")
		end
	)

	-- #89 回帰テスト: mtime(秒精度)だけの比較では、直前の処理と同一秒内に
	-- 内容が変わった場合に変化を見逃してスキップしてしまう。ファイルサイズを
	-- 補助的に比較することで、サイズが変わる変更についてはこれを検知できる。
	it(
		"mtimeが直前と同一秒でも、ファイルサイズが変化していれば自動処理はスキップされない",
		function()
			local main_mod = require("gtodo-md")
			local config = require("gtodo-md.config")
			local state_mod = require("gtodo-md.state")
			local daily_mod = require("gtodo-md.daily")
			local uv = vim.uv or vim.loop

			local data_dir = vim.fn.tempname()
			vim.fn.mkdir(data_dir .. "/projects", "p")
			config.setup({ data_dir = data_dir })
			state_mod.write_last_opened(os.date("%Y-%m-%d"))

			local todo_path = data_dir .. "/todo.md"
			vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
			vim.fn.writefile({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 既存タスク",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}, todo_path)

			-- 起動時相当の呼び出しと1回目のBufEnterで、mtime/sizeキャッシュを
			-- 初期化しておく
			daily_mod.check_daily_rollover()
			local warmup_buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(warmup_buf, todo_path)
			vim.api.nvim_buf_call(warmup_buf, function()
				vim.cmd("edit!")
			end)
			main_mod.handle_buf_enter(warmup_buf)
			vim.api.nvim_buf_delete(warmup_buf, { force = true })

			local cached_mtimes = daily_mod.get_cache()
			local pinned_mtime = cached_mtimes.todo

			-- 内容を変更(サイズが変わる)しつつ、mtimeはキャッシュ済みの値と
			-- 完全に同じ秒へ固定する(同一秒内の連続変更を模倣)
			vim.fn.writefile({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 既存タスク",
				"- [ ] 同一秒内に追加したタスク",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}, todo_path)
			uv.fs_utime(todo_path, pinned_mtime, pinned_mtime)

			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, todo_path)
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("edit!")
			end)

			main_mod.handle_buf_enter(buf)

			-- dueチェック・ソートが実際に走っていれば、追加したタスクにIDが付与される
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local found = false
			for _, line in ipairs(lines) do
				if line:match("^%- %[ %] 同一秒内に追加したタスク id:%x+$") then
					found = true
					break
				end
			end
			assert.is_true(
				found,
				"サイズが変化しているのに自動処理がスキップされた(mtimeのみの比較に戻っている): "
					.. vim.inspect(lines)
			)

			vim.api.nvim_buf_delete(buf, { force = true })
			vim.fn.delete(data_dir, "rf")
		end
	)
end)
