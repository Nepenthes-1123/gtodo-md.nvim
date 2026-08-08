-- 2ファイルにまたがる「移動」は、追記先を先に・削除元を後に確定させる
-- (logic/write_pair.lua)。
--
-- 単一ディレクトリ内で2ファイルを同時にアトミック置換する手段は無いため部分失敗は
-- 消せない。消せないなら失敗の向きを制御する — 前段(追記)が失敗すれば何も確定せず、
-- 後段(削除)が失敗しても残留状態は「両方に存在＝重複」になる。消失は復旧不能だが
-- 重複は目視できて手で消せる。
--
-- #126 でこの規律を導入した際、move_completed_tasks と cancel_current_task は
-- 直したが check_dues と editor._execute_move の inbox 分岐が漏れていた。

local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")

describe("2ファイル移動の書き込み順序", function()
	local data_dir
	local saved_data_dir
	local inbox_path
	local todo_path
	local saved_write_todo_file

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		config.setup({ data_dir = data_dir })
		inbox_path = data_dir .. "/inbox.md"
		todo_path = data_dir .. "/todo.md"
		saved_write_todo_file = io_mod.write_todo_file
	end)

	after_each(function()
		io_mod.write_todo_file = saved_write_todo_file
		config.options.data_dir = saved_data_dir
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	-- 追記先(todo.md)への書き込みだけを失敗させる。ディスク満杯・権限・並行更新検出など
	-- 実際の失敗要因を再現する代わりに、失敗の「向き」だけを検証する。
	local function fail_writes_to(target_path)
		local original = io_mod.write_todo_file
		io_mod.write_todo_file = function(path, data)
			if vim.fn.fnamemodify(path, ":p") == vim.fn.fnamemodify(target_path, ":p") then
				error("[test] simulated write failure", 0)
			end
			return original(path, data)
		end
	end

	local function todo_skeleton()
		return {
			"# Todo",
			"",
			"## " .. config.sections.TODAY,
			"",
			"## " .. config.sections.NEXT,
			"",
			"## " .. config.sections.WAITING,
			"",
			"## " .. config.sections.SOMEDAY,
			"",
		}
	end

	local function file_has(path, needle)
		for _, line in ipairs(vim.fn.readfile(path)) do
			if line:find(needle, 1, true) then
				return true
			end
		end
		return false
	end

	describe("logic.check_dues (inbox.md -> todo.md の自動昇格)", function()
		it("todo.md への追記が失敗しても inbox.md からタスクが消えない", function()
			vim.fn.writefile({ "# Inbox", "", "- [ ] 期日到達タスク due:2000-01-01" }, inbox_path)
			vim.fn.writefile(todo_skeleton(), todo_path)

			fail_writes_to(todo_path)

			local ok = pcall(require("gtodo-md.logic").check_dues, inbox_path, todo_path)

			assert.is_false(ok, "前提: 追記側の書き込みが失敗すること")
			assert.is_true(
				file_has(inbox_path, "期日到達タスク"),
				"追記に失敗したのに inbox.md から削除されている(タスクが消失する)"
			)
		end)

		it("成功時は inbox.md から消えて todo.md の Today に入る", function()
			vim.fn.writefile({ "# Inbox", "", "- [ ] 期日到達タスク due:2000-01-01" }, inbox_path)
			vim.fn.writefile(todo_skeleton(), todo_path)

			require("gtodo-md.logic").check_dues(inbox_path, todo_path)

			assert.is_false(file_has(inbox_path, "期日到達タスク"))
			assert.is_true(file_has(todo_path, "期日到達タスク"))
		end)
	end)

	describe("editor._execute_move (inbox.md -> todo.md の手動移動)", function()
		-- inbox.md をカレントバッファにしてカーソルをタスク行へ置く。
		-- _execute_move は nvim_buf_get_name(0) で対象ファイルを決めるため。
		local function open_inbox_with_task()
			vim.fn.writefile({ "# Inbox", "", "- [ ] 手動移動タスク" }, inbox_path)
			vim.fn.writefile(todo_skeleton(), todo_path)
			vim.cmd("edit " .. vim.fn.fnameescape(inbox_path))
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
			return require("gtodo-md.task").parse("- [ ] 手動移動タスク"), 3
		end

		it("todo.md への追記が失敗しても inbox.md からタスクが消えない", function()
			local task, row = open_inbox_with_task()

			fail_writes_to(todo_path)

			require("gtodo-md.editor")._execute_move(task, row, config.sections.TODAY)

			assert.is_true(
				file_has(inbox_path, "手動移動タスク"),
				"追記に失敗したのに inbox.md から削除されている(タスクが消失する)"
			)
		end)

		it("成功時は inbox.md から消えて todo.md へ移る", function()
			local task, row = open_inbox_with_task()

			require("gtodo-md.editor")._execute_move(task, row, config.sections.TODAY)

			assert.is_false(file_has(inbox_path, "手動移動タスク"))
			assert.is_true(file_has(todo_path, "手動移動タスク"))
		end)

		-- 生の :write は io.lua を経由しないためアトミック置換も並行更新検出も掛からない。
		it("inbox.md の書き戻しは io.write_lines を経由する", function()
			local task, row = open_inbox_with_task()

			local seen = {}
			local original_write_lines = io_mod.write_lines
			io_mod.write_lines = function(path, lines)
				table.insert(seen, vim.fn.fnamemodify(path, ":t"))
				return original_write_lines(path, lines)
			end

			local ok = pcall(require("gtodo-md.editor")._execute_move, task, row, config.sections.TODAY)
			io_mod.write_lines = original_write_lines

			assert.is_true(ok)
			assert.is_true(vim.tbl_contains(seen, "inbox.md"), "inbox.md が io.write_lines を経由していない")
		end)
	end)
end)
