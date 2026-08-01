local M = {}
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")
local history = require("gtodo-md.logic.history")

-- 完了タスクを done.md へ移動
function M.move_completed_tasks(inbox_path, todo_path, done_path)
	local today = os.date("%Y-%m-%d")
	local current_month = os.date("%Y-%m")
	local moved_tasks = {}

	-- 1. inbox.md から完了タスクを抽出
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
	if inbox_changed then
		io_mod.write_todo_file(inbox_path, inbox_data)
	end

	-- 2. todo.md から完了タスクを抽出
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
	if todo_changed then
		io_mod.write_todo_file(todo_path, todo_data)
	end

	if #moved_tasks == 0 then
		return false
	end

	-- 3. done.md へ追加
	local done_tasks = {}
	for _, entry in ipairs(moved_tasks) do
		local t = entry.task
		local comp_date = t.completed_at or today
		t.completed_at = nil
		t.done = comp_date
		t.from = entry.from
		table.insert(done_tasks, t)
	end

	history.append_to_history(done_path, "Done", current_month, done_tasks)
	vim.notify(string.format("Moved %d completed tasks to done.md", #moved_tasks), vim.log.levels.INFO)
	return true
end

return M
