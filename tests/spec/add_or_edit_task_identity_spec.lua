-- #163 の回帰テスト。
-- init.lua の add_or_edit_task は、編集ダイアログの応答を待つ間に対象行の
-- テキストと位置が両方変わると、元の行を見つけられずに編集開始時の行番号へ
-- 書き込んでいた。その行には別のタスクが来ているため、無関係なタスクが
-- 黙って上書きされ、元のタスクは編集されないまま残る。
--
-- prompt_task は vim.ui.input / vim.ui.select のチェーンで構成されるため、
-- 両者を同期的に即答するスタブへ差し替えて駆動する。最後のステップ(Context)の
-- 応答待ちの間に、バックグラウンドの処理が行を書き換えた状況を作る。

local TODAY = os.date("%Y-%m-%d")

describe("init.add_or_edit_task の編集対象の同定", function()
	local main_mod, config
	local data_dir, todo_path
	local saved_input, saved_select, saved_notify
	local notifications
	-- Context の応答待ちの間にバッファへ加える変更
	local mutate_during_prompt

	before_each(function()
		for name, _ in pairs(package.loaded) do
			if name == "gtodo-md" or name:match("^gtodo%-md%.") then
				package.loaded[name] = nil
			end
		end
		main_mod = require("gtodo-md")
		config = require("gtodo-md.config")

		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })
		require("gtodo-md.state").write_last_opened(TODAY)
		todo_path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")

		-- ui/prompt.lua は snacks が require できると vim.ui.input を使わない。
		assert.is_false(
			pcall(require, "snacks"),
			"snacks が解決できるため vim.ui.input のスタブが使われない"
		)

		saved_input, saved_select, saved_notify = vim.ui.input, vim.ui.select, vim.notify
		notifications = {}
		mutate_during_prompt = nil
		vim.ui.input = function(opts, on_confirm)
			if opts.prompt:find("Description", 1, true) then
				return on_confirm("EDITED")
			end
			return on_confirm("")
		end
		vim.ui.select = function(_, opts, on_choice)
			if opts.prompt:find("Context", 1, true) and mutate_during_prompt then
				mutate_during_prompt()
			end
			return on_choice("[Skip]")
		end
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = tostring(msg), level = level })
		end
	end)

	after_each(function()
		vim.ui.input, vim.ui.select, vim.notify = saved_input, saved_select, saved_notify
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	local function open_todo(lines, cursor_row)
		vim.fn.writefile(lines, todo_path)
		vim.cmd("edit " .. vim.fn.fnameescape(todo_path))
		vim.api.nvim_win_set_cursor(0, { cursor_row, 0 })
		return vim.api.nvim_get_current_buf()
	end

	local function find_line(lines, needle)
		for _, line in ipairs(lines) do
			if line:find(needle, 1, true) then
				return line
			end
		end
		return nil
	end

	local function notified_error()
		for _, n in ipairs(notifications) do
			if n.level == vim.log.levels.ERROR then
				return n.msg
			end
		end
		return nil
	end

	local SECTIONS_TAIL = { "", "## Next", "", "## Waiting", "", "## Someday", "" }

	local function with_tail(head)
		local lines = vim.deepcopy(head)
		vim.list_extend(lines, SECTIONS_TAIL)
		return lines
	end

	it(
		"行のテキストと位置が両方変わっても、無関係な行を上書きせず元のタスクを編集する",
		function()
			local buf = open_todo(
				with_tail({
					"# Todo",
					"",
					"## Today",
					"",
					"- [ ] 対象タスク created:2025-01-01",
					"- [ ] 別のタスク created:2025-01-01 id:bbb222",
				}),
				5
			)

			-- 応答待ちの間に、他インスタンスの処理で id が付与され、上に1行増えた状況
			mutate_during_prompt = function()
				vim.api.nvim_buf_set_lines(buf, 4, 6, false, {
					"- [ ] 割り込んだタスク created:2025-01-01 id:ccc333",
					"- [ ] 対象タスク created:2025-01-01 id:aaa111",
					"- [ ] 別のタスク created:2025-01-01 id:bbb222",
				})
			end

			main_mod.add_or_edit_task()

			local disk = vim.fn.readfile(todo_path)
			assert.is_nil(
				notified_error(),
				"正常系でエラー通知が出ている: " .. tostring(notified_error())
			)
			assert.is_truthy(
				find_line(disk, "割り込んだタスク"),
				"無関係な行が上書きされた: " .. vim.inspect(disk)
			)
			assert.is_truthy(
				find_line(disk, "別のタスク"),
				"無関係な行が上書きされた: " .. vim.inspect(disk)
			)
			assert.is_nil(
				find_line(disk, "対象タスク"),
				"元のタスクが編集されずに残っている: " .. vim.inspect(disk)
			)

			local edited = find_line(disk, "EDITED")
			assert.is_truthy(edited, "編集内容が保存されていない: " .. vim.inspect(disk))
			assert.are.same(
				"aaa111",
				edited:match("id:(%x+)"),
				"応答待ちの間に付与された id が引き継がれていない: " .. edited
			)
		end
	)

	it("元のタスクが見つからなければ、行番号へ書き込まずに通知して中断する", function()
		local buf = open_todo(
			with_tail({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 対象タスク created:2025-01-01 id:aaa111",
				"- [ ] 別のタスク created:2025-01-01 id:bbb222",
			}),
			5
		)

		-- 応答待ちの間に対象タスクが消え(他インスタンスで完了・移動された等)、
		-- 同じ行番号には別のタスクが来ている状況
		mutate_during_prompt = function()
			vim.api.nvim_buf_set_lines(buf, 4, 6, false, {
				"- [ ] 別のタスク created:2025-01-01 id:bbb222",
				"- [ ] さらに別のタスク created:2025-01-01 id:ccc333",
			})
		end

		main_mod.add_or_edit_task()

		local err = notified_error()
		assert.is_truthy(err, "対象タスクの消失が通知されていない")
		assert.is_truthy(err:find("no longer exists", 1, true), "想定外のエラー通知: " .. tostring(err))
		local disk = vim.fn.readfile(todo_path)
		assert.is_nil(find_line(disk, "EDITED"), "見つからないのに書き込んでいる: " .. vim.inspect(disk))
	end)
end)
