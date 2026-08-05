-- #125: 2 ファイルにまたがる書き込みの順序規約(add-then-remove)。
--
-- 単一ディレクトリ内で 2 ファイルを同時にアトミック置換する手段は無いため、
-- 部分失敗そのものは消せない。消せないなら失敗の向きを制御する:
-- 追記を先に、削除を後に行うことで、残留状態を「消失」ではなく「重複」に倒す。

local io_mod = require("gtodo-md.io")
local write_pair = require("gtodo-md.logic.write_pair")

describe("logic.write_pair.append_then_remove", function()
	it("追記 → 削除 の順で実行する", function()
		local order = {}
		write_pair.append_then_remove(function()
			table.insert(order, "append")
		end, function()
			table.insert(order, "remove")
		end)
		assert.are.same({ "append", "remove" }, order)
	end)

	it("追記が失敗したら削除は実行されない(何も確定しない)", function()
		local removed = false
		local ok = pcall(write_pair.append_then_remove, function()
			error("append failed", 0)
		end, function()
			removed = true
		end)

		assert.is_false(ok)
		assert.is_false(removed, "追記に失敗したのに削除が実行された(消失の経路)")
	end)

	it("削除が失敗しても例外は呼び出し元へ伝わる(追記は確定済み)", function()
		local appended = false
		local ok = pcall(write_pair.append_then_remove, function()
			appended = true
		end, function()
			error("remove failed", 0)
		end)

		assert.is_true(appended)
		assert.is_false(ok)
	end)
end)

describe("完了タスクの繰り込みは done.md を先に書く", function()
	local data_dir
	local config = require("gtodo-md.config")
	local logic_mod = require("gtodo-md.logic")
	local saved_data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		config.options.data_dir = data_dir
	end)

	after_each(function()
		config.options.data_dir = saved_data_dir
		vim.fn.delete(data_dir, "rf")
	end)

	it("done.md への追記が todo.md の書き換えより先に起きる", function()
		local inbox_path = data_dir .. "/inbox.md"
		local todo_path = data_dir .. "/todo.md"
		local done_path = data_dir .. "/done.md"

		vim.fn.writefile({ "# Inbox", "" }, inbox_path)
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [x] 完了したタスク completed_at:2026-01-05",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, todo_path)
		vim.fn.writefile({ "# Done", "" }, done_path)

		-- 書き込み順序を観測する
		local writes = {}
		io_mod.add_write_observer(function(path)
			table.insert(writes, vim.fn.fnamemodify(path, ":t"))
		end)

		local moved = logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)
		assert.is_true(moved)

		local done_idx, todo_idx
		for i, name in ipairs(writes) do
			if name == "done.md" and not done_idx then
				done_idx = i
			elseif name == "todo.md" and not todo_idx then
				todo_idx = i
			end
		end

		assert.is_truthy(done_idx, "done.md が書かれていない: " .. vim.inspect(writes))
		assert.is_truthy(todo_idx, "todo.md が書かれていない: " .. vim.inspect(writes))
		assert.is_true(
			done_idx < todo_idx,
			"todo.md からの削除が done.md への追記より先に起きた(消失の経路): "
				.. vim.inspect(writes)
		)

		-- 結果の確認: done.md に入り、todo.md から消えている
		local done_lines = vim.fn.readfile(done_path)
		local found = false
		for _, l in ipairs(done_lines) do
			if l:find("完了したタスク", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "done.md にタスクが記録されていない")

		for _, l in ipairs(vim.fn.readfile(todo_path)) do
			assert.is_nil(l:find("完了したタスク", 1, true), "todo.md にタスクが残っている")
		end
	end)
end)
