-- セクション見出しの扱いで、タスクが操作できない・消える・別のセクションへ移る不具合の固定。
--
-- いずれも CLI/TUI (gtodo) の移植で見つかったもので、gtodo のロードマップの決定事項に
-- 「Lua 版の不具合」として記録されている。同じデータを両方のツールで扱うため、
-- 結果を CLI と揃える。

local config = require("gtodo-md.config")
local editor_mod = require("gtodo-md.editor")
local io_mod = require("gtodo-md.io")

local function silence(fn)
	local saved = vim.notify
	local notes = {}
	vim.notify = function(msg, level)
		table.insert(notes, { msg = tostring(msg), level = level })
	end
	local ok, err = pcall(fn)
	vim.notify = saved
	if not ok then
		error(err, 0)
	end
	return notes
end

local function task_contents(items)
	local out = {}
	for _, item in ipairs(items or {}) do
		if item.type == "task" then
			table.insert(out, item.task.content)
		end
	end
	return out
end

-- 見出し行 (`## ...`) と、その下のタスクの本文を出現順に並べる。
local function outline(lines)
	local out = {}
	for _, line in ipairs(lines) do
		local heading = line:match("^(##%s+.*)$")
		local task = require("gtodo-md.task").parse(line)
		if heading then
			table.insert(out, heading)
		elseif task then
			table.insert(out, "  " .. task.content)
		end
	end
	return out
end

describe("セクション見出しの扱い", function()
	local data_dir, todo_path, inbox_path, cancelled_path, buf

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		todo_path = data_dir .. "/todo.md"
		inbox_path = data_dir .. "/inbox.md"
		cancelled_path = data_dir .. "/cancelled.md"
		silence(function()
			config.setup({ data_dir = data_dir })
		end)
	end)

	after_each(function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		buf = nil
		silence(function()
			config.setup({ data_dir = data_dir })
		end)
		vim.fn.delete(data_dir, "rf")
	end)

	-- 前回の setup() で使っていた名前を .state.json に書いてから setup() する。
	local function setup_with_last(last, sections)
		vim.fn.writefile({ vim.json.encode({ last_sections = last }) }, data_dir .. "/.state.json")
		silence(function()
			config.setup({ data_dir = data_dir, sections = sections })
		end)
	end

	local function open(path, lines)
		vim.fn.writefile(lines, path)
		buf = vim.fn.bufadd(path)
		vim.fn.bufload(buf)
		vim.api.nvim_set_current_buf(buf)
		io_mod.record_stamp(path)
	end

	local function put_cursor_on(needle)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if l:find(needle, 1, true) then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				return
			end
		end
		error("カーソル対象の行が見つからない: " .. needle)
	end

	describe("別名の照合順序", function()
		-- 見出しは「全セクションの現在の名前」→「デフォルト名」→「前回の名前」の順に照合する。
		-- キーごとに 3 つをまとめて照合すると、あるセクションの前回の名前が別のセクションの
		-- 現在の名前を奪い、見出しが別のセクションへ移る。どちらが勝つかが pairs の順で
		-- 変わるため、両方の向きを確かめる。
		it(
			"現在の名前は、他のセクションの前回の名前より優先する (TODAY が現在の名前)",
			function()
				setup_with_last({ NEXT = "あとで" }, { TODAY = "あとで" })
				local data = io_mod.parse_markdown({ "## あとで", "- [ ] a" })
				assert.are.same({ "a" }, task_contents(data.sections["あとで"]))
				assert.is_nil(data.sections["Next"])
			end
		)

		it(
			"現在の名前は、他のセクションの前回の名前より優先する (NEXT が現在の名前)",
			function()
				setup_with_last({ TODAY = "あとで" }, { NEXT = "あとで" })
				local data = io_mod.parse_markdown({ "## あとで", "- [ ] a" })
				assert.are.same({ "a" }, task_contents(data.sections["あとで"]))
				assert.is_nil(data.sections["Today"])
			end
		)

		it("デフォルト名は、他のセクションの前回の名前より優先する (Next)", function()
			setup_with_last({ TODAY = "Next" })
			local data = io_mod.parse_markdown({ "## Next", "- [ ] a" })
			assert.are.same({ "a" }, task_contents(data.sections["Next"]))
			assert.is_nil(data.sections["Today"])
		end)

		it("デフォルト名は、他のセクションの前回の名前より優先する (Today)", function()
			setup_with_last({ NEXT = "Today" })
			local data = io_mod.parse_markdown({ "## Today", "- [ ] a" })
			assert.are.same({ "a" }, task_contents(data.sections["Today"]))
			assert.is_nil(data.sections["Next"])
		end)

		-- 保存時の検証も同じ順で照合する。見出しを2つのセクションに数えると、
		-- 片方の見出しが欠けていても保存が通り、読むと別のセクションに入る。
		it("保存時の必須セクションの検証も同じ順で照合する", function()
			setup_with_last({ TODAY = "Next" })
			local missing = require("gtodo-md.validate").missing_todo_sections({
				"# Todo",
				"## Next",
				"## Waiting",
				"## Someday",
			})
			assert.are.same({ "## Today" }, missing)
		end)
	end)

	describe("別名の見出しのセクションにあるタスクの操作", function()
		-- 見出しがデフォルト名のまま (setup() で名前を変えた直後) のセクションでは、
		-- カーソル位置のセクション名を正規化せずに探していたため、タスクが見つからず
		-- 何も書かなかった。キャンセルでは cancelled.md への追記だけが済んで重複した。
		local function open_aliased_todo()
			silence(function()
				config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
			end)
			open(todo_path, {
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 対象 id:aaaaaa",
				"- [ ] 他 id:bbbbbb",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
			})
			put_cursor_on("対象")
		end

		it("カーソル位置のセクション名を現在の名前で返す", function()
			open_aliased_todo()
			assert.are.equal("今日", editor_mod.get_current_section())
		end)

		it("完了にできる", function()
			open_aliased_todo()
			silence(function()
				editor_mod.toggle_complete()
			end)
			local data = io_mod.parse_markdown(vim.fn.readfile(todo_path))
			local done = vim.tbl_filter(function(item)
				return item.type == "task" and item.task.content == "対象"
			end, data.sections["今日"])
			assert.are.equal(1, #done)
			assert.are.equal("x", done[1].task.status)
		end)

		it("キャンセルすると todo.md から取り除き、重複させない", function()
			open_aliased_todo()
			local notes = silence(function()
				editor_mod.cancel_current_task()
			end)
			local data = io_mod.parse_markdown(vim.fn.readfile(todo_path))
			assert.are.same({ "他" }, task_contents(data.sections["今日"]))
			assert.is_truthy(table.concat(vim.fn.readfile(cancelled_path), "\n"):find("対象", 1, true))
			for _, n in ipairs(notes) do
				assert.is_falsy(n.msg:find("could not be removed", 1, true), n.msg)
			end
		end)

		it("別のセクションへ移せる", function()
			open_aliased_todo()
			silence(function()
				editor_mod.move_current_task_to(config.sections.NEXT)
			end)
			local data = io_mod.parse_markdown(vim.fn.readfile(todo_path))
			assert.are.same({ "他" }, task_contents(data.sections["今日"]))
			assert.are.same({ "対象" }, task_contents(data.sections["Next"]))
		end)
	end)

	describe("見出しの無いセクション", function()
		-- セクションを作っても書き出す順序 (section_order) に加えていなかったため、
		-- 書き出すときにそのセクションごと落ち、加えたタスクが消えていた。
		it("inbox.md から見出しの無いセクションへ移しても、タスクが消えない", function()
			vim.fn.writefile({ "# Todo", "", "## Today", "", "## Next" }, todo_path)
			open(inbox_path, { "# Inbox", "", "- [ ] 待つ id:cccccc" })
			put_cursor_on("待つ")

			silence(function()
				local saved = vim.ui.input
				vim.ui.input = function(_, cb)
					cb("bob")
				end
				local ok, err = pcall(editor_mod.move_current_task_to, config.sections.WAITING)
				vim.ui.input = saved
				assert(ok, err)
			end)

			assert.are.same({ "## Today", "## Next", "## Waiting", "  待つ" }, outline(vim.fn.readfile(todo_path)))
			assert.are.same({}, outline(vim.fn.readfile(inbox_path)))
		end)

		it("見出しの無いセクションへ追加しても、タスクが消えない", function()
			vim.fn.writefile({ "# Inbox" }, inbox_path)
			open(todo_path, { "# Todo", "", "## Next", "", "## Waiting", "", "## Someday" })
			put_cursor_on("# Todo") -- 最初の見出しより上で追加すると Today へ入る

			local prompt = require("gtodo-md.ui.prompt")
			local saved = prompt.prompt_task
			prompt.prompt_task = function(_, cb)
				cb({ status = " ", content = "新しい" })
			end
			local ok, err = pcall(silence, function()
				require("gtodo-md").add_or_edit_task()
			end)
			prompt.prompt_task = saved
			assert(ok, err)

			assert.are.same(
				{ "## Next", "## Waiting", "## Someday", "## Today", "  新しい" },
				outline(vim.fn.readfile(todo_path))
			)
		end)
	end)

	describe("## default という見出し", function()
		-- 最初の見出しより前の行を内部で "default" という名前のセクションとして持って
		-- いたため、同じ名前の見出しと衝突し、見出しが消えてタスクが先頭へ移っていた。
		it("見出しを残し、タスクをその下に置いたまま書き戻す", function()
			local lines = {
				"# Todo",
				"",
				"- [ ] 見出しより前 id:dddddd",
				"",
				"## Today",
				"",
				"## default",
				"",
				"- [ ] defaultの下 id:eeeeee",
			}
			io_mod.write_todo_file(todo_path, io_mod.parse_markdown(lines))

			assert.are.same(
				{ "  見出しより前", "## Today", "## default", "  defaultの下" },
				outline(vim.fn.readfile(todo_path))
			)
		end)

		it("inbox.md の見出しより前のタスクは、これまでどおり読める", function()
			local data = io_mod.parse_markdown({ "# Inbox", "", "- [ ] a", "## default", "- [ ] b" })
			assert.are.same({ "a" }, task_contents(data.sections[io_mod.PREAMBLE]))
			assert.are.same({ "b" }, task_contents(data.sections["default"]))
		end)
	end)
end)
