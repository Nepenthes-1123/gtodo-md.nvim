-- #94 回帰テスト: config.sections(Today/Next/Waiting/Someday)を
-- setup()でカスタム名に変更できるようにする。
--
-- 設計上の要件: カスタム名を設定しても、デフォルト名(Today等)の見出しを
-- ユーザーに手動でリネームさせない。io.parse_markdown がデフォルト名の
-- 見出しをその場でカスタム名へ正規化し、次回保存時に write_todo_file が
-- 新しい名前で書き戻す。BufWritePreのバリデーションもカスタム名・
-- デフォルト名の両方を許容する。

local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")

describe("config.sections のカスタム化 (#94)", function()
	local data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
	end)

	after_each(function()
		config.setup({ data_dir = data_dir }) -- 次のテストへ影響しないよう既定に戻す
		vim.fn.delete(data_dir, "rf")
	end)

	it("setup({sections=...})でTODAYの見出し名を変更でき、他のキーは既定のまま残る", function()
		config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
		assert.are.same("今日", config.sections.TODAY)
		assert.are.same("Next", config.sections.NEXT)
		assert.are.same("Waiting", config.sections.WAITING)
		assert.are.same("Someday", config.sections.SOMEDAY)
	end)

	it("section_aliasesはカスタム名設定時に[カスタム名, デフォルト名]の順で返す", function()
		config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
		assert.are.same({ "今日", "Today" }, config.section_aliases("TODAY"))
		assert.are.same({ "Next" }, config.section_aliases("NEXT"))
	end)

	it(
		"parse_markdownは、カスタム名設定時にデフォルト名の見出しをその場でカスタム名へ正規化する",
		function()
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })

			local data = io_mod.parse_markdown({
				"# Todo",
				"",
				"## Today", -- まだリネームしていない既存ファイルを想定
				"",
				"- [ ] タスクA",
			})

			assert.is_not_nil(
				data.sections["今日"],
				"正規化後のカスタム名でセクションが見つからない"
			)
			assert.is_nil(
				data.sections["Today"],
				"デフォルト名のセクションが正規化されず別途残っている"
			)
			assert.equals("タスクA", data.sections["今日"][1].task.content)
		end
	)

	it(
		"正規化後にwrite_todo_fileで書き戻すと、見出しがカスタム名に書き換わる(手動リネーム不要)",
		function()
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })

			local data = io_mod.parse_markdown({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] タスクA",
			})

			local todo_path = data_dir .. "/todo.md"
			io_mod.write_todo_file(todo_path, data)
			local written = vim.fn.readfile(todo_path)

			local found_new, found_old = false, false
			for _, l in ipairs(written) do
				if l == "## 今日" then
					found_new = true
				end
				if l == "## Today" then
					found_old = true
				end
			end
			assert.is_true(
				found_new,
				"書き戻し後にカスタム名の見出しが無い: " .. vim.inspect(written)
			)
			assert.is_false(
				found_old,
				"書き戻し後もデフォルト名の見出しが残っている: " .. vim.inspect(written)
			)
		end
	)

	describe("BufWritePreバリデーション", function()
		local function try_write(lines)
			local todo_path = data_dir .. "/todo.md"
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, todo_path)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			local ok, err = pcall(function()
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("write")
				end)
			end)

			vim.api.nvim_buf_delete(buf, { force = true })
			return ok, err
		end

		before_each(function()
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
			require("gtodo-md").setup_autocmds()
		end)

		it(
			"カスタム名設定時でも、デフォルト名(Today)の見出しのままなら保存できる(#94)",
			function()
				local ok = try_write({
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
				})
				assert.is_true(
					ok,
					"デフォルト名の見出しのままだと保存がブロックされてしまう"
				)
			end
		)

		it("カスタム名(今日)の見出しでも要件を満たせる", function()
			local ok = try_write({
				"# Todo",
				"",
				"## 今日",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			})
			assert.is_true(ok, "カスタム名の見出しがあるのに保存がブロックされた")
		end)

		it("カスタム名・デフォルト名どちらの見出しも無ければ保存を中断する", function()
			local ok, err = try_write({
				"# Todo",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			})
			assert.is_false(ok)
			assert.is_true(
				tostring(err):find("今日", 1, true) ~= nil,
				"エラーメッセージにカスタム名が含まれていない: " .. tostring(err)
			)
		end)
	end)

	-- カスタム名を変更・削除した直後、ファイル側の見出しがまだ前回の名前の
	-- ままでも保存がブロックされないこと(前回の名前を1世代分だけ覚える)。
	describe("セクション名を変更・削除した直後の互換性", function()
		-- #94 とは無関係なVim側の安全確認(:editを経由していない新規バッファ
		-- から既存パスへ書き込む際のE13: File exists)を避けるため write! を
		-- 使う。BufWritePreのバリデーション自体は ! の有無に関わらず通常通り
		-- 発火する。
		local function try_write(lines)
			local todo_path = data_dir .. "/todo.md"
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, todo_path)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			local ok, err = pcall(function()
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("write!")
				end)
			end)

			vim.api.nvim_buf_delete(buf, { force = true })
			return ok, err
		end

		before_each(function()
			require("gtodo-md").setup_autocmds()
		end)

		it(
			"カスタム名で保存した後、設定を削除してデフォルトへ戻しても前回の見出しのまま保存できる",
			function()
				config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
				local ok1 = try_write({
					"# Todo",
					"",
					"## 今日",
					"",
					"## Next",
					"",
					"## Waiting",
					"",
					"## Someday",
					"",
				})
				assert.is_true(ok1)

				-- sections 設定を削除(デフォルトへ戻す)。ファイルの見出しは
				-- まだ "## 今日" のまま(手動リネームしていない)。
				config.setup({ data_dir = data_dir })

				local ok2 = try_write({
					"# Todo",
					"",
					"## 今日",
					"",
					"## Next",
					"",
					"## Waiting",
					"",
					"## Someday",
					"",
				})
				assert.is_true(
					ok2,
					"設定を削除した直後、前回のカスタム名の見出しのままでは保存できなかった(#94)"
				)
			end
		)

		it(
			"設定を戻した後にsort_todo_fileが走ると、見出しが新しい名前へ自動的に書き換わる",
			function()
				config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
				local todo_path = data_dir .. "/todo.md"
				io_mod.write_lines(todo_path, {
					"# Todo",
					"",
					"## 今日",
					"",
					"- [ ] タスクA",
					"",
					"## Next",
					"",
					"## Waiting",
					"",
					"## Someday",
					"",
				})

				config.setup({ data_dir = data_dir })
				require("gtodo-md.logic").sort_todo_file(todo_path)

				local written = vim.fn.readfile(todo_path)
				local found_new, found_old = false, false
				for _, l in ipairs(written) do
					if l == "## Today" then
						found_new = true
					end
					if l == "## 今日" then
						found_old = true
					end
				end
				assert.is_true(
					found_new,
					"書き戻し後にデフォルト名の見出しが無い: " .. vim.inspect(written)
				)
				assert.is_false(
					found_old,
					"書き戻し後も前回のカスタム名の見出しが残っている: " .. vim.inspect(written)
				)
			end
		)
	end)

	it(
		"dashboard.get_tasks_linesは、TODAYがカスタム名でも該当セクションのタスクを一覧に含める",
		function()
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
			local dashboard_mod = require("gtodo-md.integrations.dashboard")

			io_mod.write_lines(data_dir .. "/todo.md", {
				"# Todo",
				"",
				"## 今日",
				"",
				"- [ ] 今日やるタスク",
				"",
			})

			local result = dashboard_mod.get_tasks_lines(5)
			local found = false
			for _, entry in ipairs(result) do
				if entry.text and entry.text:find("今日やるタスク", 1, true) then
					found = true
				end
			end
			assert.is_true(
				found,
				"カスタム名セクションのタスクが一覧に含まれていない: " .. vim.inspect(result)
			)
		end
	)
end)
