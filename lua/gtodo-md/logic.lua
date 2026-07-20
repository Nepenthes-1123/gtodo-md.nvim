local M = {}
local task_mod = require("gtodo-md.task")
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")

local mem_last_notify_time = 0
local mem_last_notify_content = ""

-- items リストをソートする内部ヘルパー
-- 入力: { type="task"|"text", ... } のフラット配列
-- 出力: 同形式でタスクのみソートされた新しい配列
local function sort_items(items)
	local tasks = {}
	local task_indices = {}
	for i, item in ipairs(items) do
		if item.type == "task" then
			item.original_index = i
			table.insert(tasks, item)
			table.insert(task_indices, i)
		end
	end

	table.sort(tasks, function(a, b)
		local t_a = a.task
		local t_b = b.task
		-- 1. [x] 付きは最末尾に固定
		local done_a = (t_a.status == "x")
		local done_b = (t_b.status == "x")
		if done_a ~= done_b then
			return done_b
		end

		-- 2. dueあり優先、dueなしは末尾
		local has_due_a = (t_a.due ~= nil and t_a.due ~= "")
		local has_due_b = (t_b.due ~= nil and t_b.due ~= "")
		if has_due_a ~= has_due_b then
			return has_due_a
		end

		if has_due_a and has_due_b then
			if t_a.due ~= t_b.due then
				return t_a.due < t_b.due
			end
		end

		-- 3. 優先度 (A > B > C ... > Z) ※Zは優先度指定なし扱い
		-- task.lua が parse 時に task.priority へ分離済み（P2-1 修正）
		local p_a = t_a.priority or "Z"
		local p_b = t_b.priority or "Z"
		if p_a ~= p_b then
			return p_a < p_b
		end

		-- 4. stable sort
		return a.original_index < b.original_index
	end)

	local new_items = {}
	for i, item in ipairs(items) do
		new_items[i] = item
	end
	for i, idx in ipairs(task_indices) do
		new_items[idx] = { type = "task", task = tasks[i].task }
	end
	return new_items
end

-- セクション内のタスクをソートする
-- 入力: data.sections[sec]（ネスト構造 { items, subsections } ）
-- 出力: 同形式で items と各 subsections.items がそれぞれソートされたもの
function M.sort_section_tasks(sec_data)
	-- ネスト構造（現行実装）
	if type(sec_data) == "table" and sec_data.items ~= nil then
		local sorted_items = sort_items(sec_data.items)
		local sorted_subsections = {}
		for _, sub in ipairs(sec_data.subsections or {}) do
			table.insert(sorted_subsections, {
				name = sub.name,
				items = sort_items(sub.items),
			})
		end
		return { items = sorted_items, subsections = sorted_subsections }
	end

	-- 旧フラット配列への安全フォールバック（実際には到達しない）
	return sort_items(sec_data or {})
end

-- todo.mdをソートする
function M.sort_todo_file(filepath)
	local data = io_mod.read_todo_file(filepath)
	for _, sec in ipairs(data.section_order) do
		data.sections[sec] = M.sort_section_tasks(data.sections[sec])
	end
	io_mod.write_todo_file(filepath, data)
end

local function get_last_notify_state(persist)
	if persist then
		local utils = require("gtodo-md.utils")
		return utils.read_notify_state()
	else
		return mem_last_notify_time, mem_last_notify_content
	end
end

local function set_last_notify_state(persist, time, content)
	if persist then
		local utils = require("gtodo-md.utils")
		utils.write_notify_state(time, content)
	else
		mem_last_notify_time = time
		mem_last_notify_content = content
	end
end

-- dueチェック・自動移動
function M.check_dues(inbox_path, todo_path)
	local today = os.date("%Y-%m-%d")
	local moved_count = 0
	local auto_move_inbox = config.get("auto_move_inbox_to_today")

	-- 1. inbox.md の dueチェック
	local inbox_data = io_mod.read_todo_file(inbox_path)
	local inbox_warnings = {}
	local inbox_changed = false
	local items_to_move = {}
	local future_items_to_move = {}

	if inbox_data.sections["default"] then
		local sec = inbox_data.sections["default"]
		local sec_items = io_mod.get_section_items(sec)
		local remaining = {}
		for _, item in ipairs(sec_items) do
			if item.type == "task" and item.task.status ~= "x" and item.task.due then
				if item.task.due <= today then
					if auto_move_inbox then
						table.insert(items_to_move, item)
						inbox_changed = true
					else
						table.insert(
							inbox_warnings,
							string.format("Inbox: %s (due: %s)", item.task.content, item.task.due)
						)
						table.insert(remaining, item)
					end
				else
					table.insert(remaining, item)
				end
			else
				table.insert(remaining, item)
			end
		end
		-- items のみ差し替え（subsections は inbox.md では使用しないため不変）
		if type(sec) == "table" and sec.items ~= nil then
			sec.items = remaining
		else
			inbox_data.sections["default"] = remaining
		end
	end

	if inbox_changed then
		io_mod.write_todo_file(inbox_path, inbox_data)
	end

	local persist = config.get("due_notification_persist")

	if #inbox_warnings > 0 then
		local warning_str = table.concat(inbox_warnings, "\n")
		local cooldown = config.get("due_notification_cooldown")
		local last_time, last_content = get_last_notify_state(persist)
		local now = os.time()

		if not last_time or last_time == 0 or warning_str ~= last_content or (now - last_time) >= cooldown then
			vim.notify("Overdue/Due tasks in Inbox:\n" .. warning_str, vim.log.levels.WARN)
			set_last_notify_state(persist, now, warning_str)
		end
	else
		set_last_notify_state(persist, 0, "")
	end

	-- 2. todo.md の dueチェック (Inbox / Next / Someday -> Today)
	local todo_data = io_mod.read_todo_file(todo_path)
	local todo_changed = false

	if not todo_data.sections[config.sections.TODAY] then
		todo_data.sections[config.sections.TODAY] = { items = {}, subsections = {} }
		table.insert(todo_data.section_order, 1, config.sections.TODAY)
	end

	for _, item in ipairs(items_to_move) do
		table.insert(io_mod.get_section_items(todo_data.sections[config.sections.TODAY]), item)
		moved_count = moved_count + 1
		todo_changed = true
	end

	if #future_items_to_move > 0 then
		if not todo_data.sections[config.sections.WAITING] then
			todo_data.sections[config.sections.WAITING] = { items = {}, subsections = {} }
		end
		for _, item in ipairs(future_items_to_move) do
			table.insert(io_mod.get_section_items(todo_data.sections[config.sections.WAITING]), item)
			moved_count = moved_count + 1
			todo_changed = true
		end
	end

	for _, from_sec in ipairs({ config.sections.NEXT, config.sections.SOMEDAY, config.sections.WAITING }) do
		if todo_data.sections[from_sec] then
			local sec = todo_data.sections[from_sec]
			local sec_items = io_mod.get_section_items(sec)
			local remaining_items = {}
			for _, item in ipairs(sec_items) do
				if item.type == "task" and item.task.status ~= "x" and item.task.due and item.task.due <= today then
					item.task.wait = nil -- 自動移動時も wait: を剥がす
					table.insert(io_mod.get_section_items(todo_data.sections[config.sections.TODAY]), item)
					moved_count = moved_count + 1
					todo_changed = true
				else
					table.insert(remaining_items, item)
				end
			end
			-- items のみ差し替え（subsections は不変）
			if type(sec) == "table" and sec.items ~= nil then
				sec.items = remaining_items
			else
				todo_data.sections[from_sec] = remaining_items
			end
		end
	end

	if todo_changed then
		io_mod.write_todo_file(todo_path, todo_data)
		vim.notify(string.format("Moved %d tasks to Today due to deadline.", moved_count), vim.log.levels.INFO)
	end

	return todo_changed
end

-- 履歴ファイル (done.md / cancelled.md) へタスクを追記する
function M.append_to_history(filepath, header_title, section_name, tasks)
	local lines = {}
	local file_exists = vim.fn.filereadable(filepath) == 1

	if file_exists then
		local f = io.open(filepath, "r")
		if f then
			for line in f:lines() do
				table.insert(lines, line)
			end
			f:close()
		end
	else
		table.insert(lines, "# " .. header_title)
		table.insert(lines, "")
	end

	-- セクションがすでに存在するかチェック
	local has_section = false
	for _, line in ipairs(lines) do
		if line == "## " .. section_name then
			has_section = true
			break
		end
	end

	if not has_section then
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		table.insert(lines, "## " .. section_name)
		table.insert(lines, "")
	end

	for _, t in ipairs(tasks) do
		table.insert(lines, task_mod.serialize(t))
	end

	io_mod.write_lines(filepath, lines)
end

-- 完了タスクを done.md へ移動
function M.move_completed_tasks(inbox_path, todo_path, done_path)
	local today = os.date("%Y-%m-%d")
	local current_month = os.date("%Y-%m")
	local moved_tasks = {}

	-- 1. inbox.md から完了タスクを抽出
	local inbox_data = io_mod.read_todo_file(inbox_path)
	local inbox_changed = false
	if inbox_data.sections["default"] then
		local sec = inbox_data.sections["default"]
		local sec_items = io_mod.get_section_items(sec)
		local remaining = {}
		for _, item in ipairs(sec_items) do
			if item.type == "task" and item.task.status == "x" then
				table.insert(moved_tasks, { task = item.task, from = "inbox" })
				inbox_changed = true
			else
				table.insert(remaining, item)
			end
		end
		if type(sec) == "table" and sec.items ~= nil then
			sec.items = remaining
		else
			inbox_data.sections["default"] = remaining
		end
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
			local sec_data = todo_data.sections[sec]
			local sec_items = io_mod.get_section_items(sec_data)
			local remaining = {}
			for _, item in ipairs(sec_items) do
				if item.type == "task" and item.task.status == "x" then
					table.insert(moved_tasks, { task = item.task, from = sec:lower() })
					todo_changed = true
				else
					table.insert(remaining, item)
				end
			end
			-- items のみ差し替え（subsections は不変）
			if type(sec_data) == "table" and sec_data.items ~= nil then
				sec_data.items = remaining
			else
				todo_data.sections[sec] = remaining
			end
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

	M.append_to_history(done_path, "Done", current_month, done_tasks)
	vim.notify(string.format("Moved %d completed tasks to done.md", #moved_tasks), vim.log.levels.INFO)
	return true
end

return M
