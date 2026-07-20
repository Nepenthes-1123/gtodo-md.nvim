local M = {}
local io_mod = require("gtodo-md.io")

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

return M
