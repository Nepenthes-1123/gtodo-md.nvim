-- init.lua の add_or_edit_task(キーマップ prefix.."a" / 適応的なタスク追加・編集)の
-- 編集確定パスの回帰テスト。
--
-- この関数はこれまで1件もテストが無かった。中核は「編集内容をどう確定させるか」で、
-- 以前は生の `silent! write` を使っていた。`silent!` は BufWritePre の検証エラーを
-- 含む一切の失敗を握り潰すため、ユーザーには成功したように見えてディスクへは
-- 保存されず、次の外部変更リロードで編集内容が静かに失われていた。
-- 現在は io.write_lines を pcall で包み、失敗を通知して中断する。
--
-- prompt_task は vim.ui.input / vim.ui.select のチェーンで構成されるため、
-- 両者を同期的に即答するスタブへ差し替えて駆動する
-- (editor_task_ops_spec.lua / transition_move_spec.lua と同じ慣習)。

local TODAY = os.date("%Y-%m-%d")

local function todo_fixture(task_line)
	return {
		"# Todo",
		"",
		"## Today",
		"",
		task_line,
		"",
		"## Next",
		"",
		"## Waiting",
		"",
		"## Someday",
		"",
	}
end

describe("init.add_or_edit_task の編集確定", function()
	local main_mod, config, io_mod
	local data_dir, todo_path, inbox_path
	local saved_input, saved_select, saved_notify
	local notifications

	-- prompt_task の各ステップへの回答。プロンプト文字列の前方一致で引く。
	local answers

	local function stub_ui()
		saved_input = vim.ui.input
		saved_select = vim.ui.select
		saved_notify = vim.notify
		notifications = {}

		vim.ui.input = function(opts, on_confirm)
			local prompt = opts and opts.prompt or ""
			for key, value in pairs(answers.input) do
				if prompt:find(key, 1, true) then
					return on_confirm(value)
				end
			end
			return on_confirm("")
		end

		vim.ui.select = function(_, opts, on_choice)
			local prompt = opts and opts.prompt or ""
			for key, value in pairs(answers.select) do
				if prompt:find(key, 1, true) then
					return on_choice(value)
				end
			end
			return on_choice("[Skip]")
		end

		vim.notify = function(msg, level)
			table.insert(notifications, { msg = tostring(msg), level = level })
		end
	end

	-- ui/prompt.lua は snacks が require できる場合 vim.ui.input ではなく
	-- snacks.input を使う。このスペックは「snacks が入っていないこと」に暗黙に
	-- 依存するため、前提が崩れたときに原因が読めるよう明示的に確認する
	-- (tests/minimal_init.lua は runtimepath に snacks を載せない)。
	local function assert_ui_stub_is_reachable()
		assert.is_false(
			pcall(require, "snacks"),
			"snacks が解決できるため vim.ui.input のスタブが使われない"
		)
	end

	local function restore_ui()
		vim.ui.input = saved_input
		vim.ui.select = saved_select
		vim.notify = saved_notify
	end

	local function notified_error()
		for _, n in ipairs(notifications) do
			if n.level == vim.log.levels.ERROR then
				return n.msg
			end
		end
		return nil
	end

	before_each(function()
		-- io.lua の世代スタンプ表など、モジュールローカルの永続状態を毎回リセットする
		-- (autoread_skip_spec.lua と同じ理由。一部だけのリロードは不可)。
		for name, _ in pairs(package.loaded) do
			if name == "gtodo-md" or name:match("^gtodo%-md%.") then
				package.loaded[name] = nil
			end
		end
		main_mod = require("gtodo-md")
		config = require("gtodo-md.config")
		io_mod = require("gtodo-md.io")

		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })
		require("gtodo-md.state").write_last_opened(TODAY)

		todo_path = data_dir .. "/todo.md"
		inbox_path = data_dir .. "/inbox.md"
		vim.fn.writefile({ "# Inbox", "" }, inbox_path)

		answers = { input = {}, select = {} }
		stub_ui()
		assert_ui_stub_is_reachable()
	end)

	after_each(function()
		restore_ui()
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	-- カーソルをタスク行に置いた todo.md バッファを開く。
	local function open_todo_on_task(task_line)
		vim.fn.writefile(todo_fixture(task_line), todo_path)
		vim.cmd("edit " .. vim.fn.fnameescape(todo_path))
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_win_set_cursor(0, { 5, 0 })
		return buf
	end

	local function disk_has_prefix(prefix)
		for _, line in ipairs(vim.fn.readfile(todo_path)) do
			if line == prefix or line:match("^" .. vim.pesc(prefix) .. " id:%x+$") then
				return true
			end
		end
		return false
	end

	-- 「ディスクに載ったこと」だけを見ると、生の `silent! write` 実装でも通過してしまう
	-- (実際に旧実装へ戻して確認済み)。確定経路そのものを検証するため、
	--   1. io.write_lines が編集対象のパスに対して呼ばれること
	--   2. その過程で BufWritePost が一度も発火しないこと
	-- を併せて確認する。2 は io.write_lines が `:write` を使わないという契約
	-- (io_write_lines_spec.lua と同じ不変条件)で、`silent! write` へ戻すと必ず破れる。
	it("編集確定が io.write_lines を通り、:write を経由せずディスクへ載る", function()
		local buf = open_todo_on_task("- [ ] 元のタスク created:2025-01-01 id:aaa111")
		answers.input["Description"] = "編集後のタスク"

		local written_paths = {}
		local original_write_lines = io_mod.write_lines
		io_mod.write_lines = function(path, lines)
			table.insert(written_paths, path)
			return original_write_lines(path, lines)
		end

		local buf_write_posts = 0
		local probe = vim.api.nvim_create_augroup("GtodoMdAddOrEditProbe", { clear = true })
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = probe,
			buffer = buf,
			callback = function()
				buf_write_posts = buf_write_posts + 1
			end,
		})

		local ok, err = pcall(main_mod.add_or_edit_task)

		io_mod.write_lines = original_write_lines
		vim.api.nvim_del_augroup_by_id(probe)
		assert.is_true(ok, tostring(err))

		assert.are.same(todo_path, written_paths[1], "編集確定が io.write_lines を通っていない")
		assert.are.same(0, buf_write_posts, "編集確定が `:write` を経由している")

		local disk = vim.fn.readfile(todo_path)
		assert.is_true(
			disk_has_prefix("- [ ] 編集後のタスク created:2025-01-01"),
			"編集内容がディスクへ保存されていない: " .. vim.inspect(disk)
		)
		for _, line in ipairs(disk) do
			assert.is_nil(line:match("元のタスク"), "編集前の行が残っている: " .. line)
		end
		assert.is_nil(notified_error(), "正常系でエラー通知が出ている")
	end)

	it("既存の id: は編集後も保持される(同定キーを壊さない)", function()
		open_todo_on_task("- [ ] 元のタスク created:2025-01-01 id:aaa111")
		answers.input["Description"] = "編集後のタスク"

		main_mod.add_or_edit_task()

		local found
		for _, line in ipairs(vim.fn.readfile(todo_path)) do
			if line:match("編集後のタスク") then
				found = line
			end
		end
		assert.is_truthy(found)
		assert.are.same(
			"aaa111",
			found:match("id:(%x+)"),
			"編集で id: が振り直されている: " .. tostring(found)
		)
	end)

	-- 本命の回帰: 書き込み失敗を握り潰さないこと。
	-- io.write_lines は並行更新を検出すると error を投げる。`silent! write` 実装では
	-- この失敗が一切表に出ず、ユーザーは保存できたと誤認していた。
	--
	-- 注意: このケースはディスクとバッファを意図的に食い違わせるため、万一 `:write`
	-- を経由する実装へ戻ると Vim の "The file has been changed since reading it!!!"
	-- 確認プロンプトに当たる。`silent!` はこの対話プロンプトを抑止しないため、
	-- headless では応答が来ず**失敗ではなくハング**として現れる(CI では job timeout)。
	-- 退行を assert で早く落とすのは上の「io.write_lines を通り、:write を経由せず」
	-- のテストの役割で、こちらは失敗時の通知と中断そのものを固定する。
	it("書き込みに失敗した場合は通知して中断し、ディスクを書き換えない", function()
		open_todo_on_task("- [ ] 元のタスク created:2025-01-01 id:aaa111")
		answers.input["Description"] = "編集後のタスク"

		-- 「読んだ時点」のスタンプを記録したうえで、他インスタンスがディスクを
		-- 書き換えた状況を作る(バッファの内容とも食い違わせる)。
		io_mod.record_stamp(todo_path)
		local external = todo_fixture("- [ ] 他インスタンスが置き換えたタスク id:bbb222")
		table.insert(external, "- [ ] さらに追記された行")
		vim.fn.writefile(external, todo_path)

		main_mod.add_or_edit_task()

		local err = notified_error()
		assert.is_truthy(err, "書き込み失敗が通知されていない(握り潰されている)")
		assert.is_truthy(
			err:find("他のプロセスによって更新されています", 1, true),
			"想定外のエラー通知: " .. tostring(err)
		)
		assert.are.same(
			external,
			vim.fn.readfile(todo_path),
			"失敗したはずの書き込みがディスクへ反映されている"
		)
	end)

	-- 編集ダイアログの応答待ちの間に行が消えた場合、行番号をそのまま使うと
	-- 無関係な行を書き換える。範囲外なら通知して中断する。
	it("編集確定までに対象行が消えていた場合は通知して中断する", function()
		local buf = open_todo_on_task("- [ ] 元のタスク created:2025-01-01 id:aaa111")
		answers.input["Description"] = "編集後のタスク"

		-- prompt_task の最後のステップ(Context の選択)で、応答待ちの間に
		-- バッファが縮んだ状況を作る。
		local original_select = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			if opts and opts.prompt and opts.prompt:find("Context", 1, true) then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Todo" })
			end
			return original_select(items, opts, on_choice)
		end

		main_mod.add_or_edit_task()

		vim.ui.select = original_select

		local err = notified_error()
		assert.is_truthy(err, "対象行の消失が通知されていない")
		assert.is_truthy(err:find("no longer exists", 1, true), "想定外のエラー通知: " .. tostring(err))
	end)
end)
