local M = {}
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")
local history = require("gtodo-md.logic.history")
local write_pair = require("gtodo-md.logic.write_pair")

-- 完了タスクを done.md へ移動
--
-- 順序は **done.md への追記が先、inbox/todo からの削除が後**(write_pair 参照)。
-- 以前は削除を先に行っていたため、追記が失敗するとタスクがどのファイルにも
-- 残らず消失していた。現在は追記が失敗すれば削除元は一切触られず、
-- 削除が失敗した場合は「両方に存在 = 重複」で済む。
function M.move_completed_tasks(inbox_path, todo_path, done_path)
	local today = os.date("%Y-%m-%d")
	local moved_tasks = {}

	-- 1. inbox.md から完了タスクを抽出する(この時点では書き込まない)
	local inbox_data = io_mod.read_todo_file(inbox_path)
	local inbox_changed = false
	if inbox_data.sections["default"] then
		local sec_items = inbox_data.sections["default"]
		local remaining = {}
		for _, item in ipairs(sec_items) do
			if item.type == "task" and item.task.status == "x" then
				table.insert(moved_tasks, { task = item.task, from = "inbox" })
				inbox_changed = true
			else
				table.insert(remaining, item)
			end
		end
		inbox_data.sections["default"] = remaining
	end

	-- 2. todo.md から完了タスクを抽出する(この時点では書き込まない)
	local todo_data = io_mod.read_todo_file(todo_path)
	local todo_changed = false
	for _, sec in ipairs({
		config.sections.TODAY,
		config.sections.NEXT,
		config.sections.WAITING,
		config.sections.SOMEDAY,
	}) do
		if todo_data.sections[sec] then
			local sec_items = todo_data.sections[sec]
			local remaining = {}
			for _, item in ipairs(sec_items) do
				if item.type == "task" and item.task.status == "x" then
					table.insert(moved_tasks, { task = item.task, from = sec:lower() })
					todo_changed = true
				else
					table.insert(remaining, item)
				end
			end
			todo_data.sections[sec] = remaining
		end
	end

	if #moved_tasks == 0 then
		return false
	end

	-- 3. 月ごとに仕分ける。
	--
	-- 月見出しは繰り込みを実行した日ではなく completed_at の月で振り分ける。
	-- 実行日を基準にすると、月をまたいで放置された完了タスクや、日付を遡って
	-- 完了させたタスクが、実際に完了した月とは違う見出しの下に記録されてしまう。
	local by_month = {}
	local month_order = {}
	for _, entry in ipairs(moved_tasks) do
		local t = entry.task
		local comp_date = t.completed_at or today
		t.completed_at = nil
		t.done = comp_date
		t.from = entry.from

		-- 手編集で不正な日付が入っている場合は当月へ寄せる
		local month = comp_date:match("^(%d%d%d%d%-%d%d)") or os.date("%Y-%m")
		if not by_month[month] then
			by_month[month] = {}
			table.insert(month_order, month)
		end
		table.insert(by_month[month], t)
	end
	table.sort(month_order)

	-- 4. 追記 → (段間の同期) → 削除 の順で確定させる
	write_pair.append_then_remove(function()
		for _, month in ipairs(month_order) do
			history.append_to_history(done_path, "Done", month, by_month[month])
		end
	end, function()
		if inbox_changed then
			io_mod.write_todo_file(inbox_path, inbox_data)
		end
		if todo_changed then
			io_mod.write_todo_file(todo_path, todo_data)
		end
	end, config.get("data_dir"))

	vim.notify(string.format("Moved %d completed tasks to done.md", #moved_tasks), vim.log.levels.INFO)
	return true
end

return M
