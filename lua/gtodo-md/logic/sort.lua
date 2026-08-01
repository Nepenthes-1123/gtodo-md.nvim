local M = {}
local io_mod = require("gtodo-md.io")

-- 1件のタスクグループ（非タスク行を跨がない連続区間）をソートする比較関数
local function compare_tasks(a, b)
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
end

-- items リストをソートする内部ヘルパー
-- 入力: { type="task"|"text", ... } のフラット配列
-- 出力: 同形式でタスクのみソートされた新しい配列
--
-- P0-1 の教訓: 見出し(### 等)やその他のテキスト行を挟んでタスクを並び替えると、
-- タスクが元居たテキストブロックの外へ移動してしまう(サブセクション崩壊)。
-- これを一般化して防ぐため、非タスク行を「並び替えの境界」として扱い、
-- 境界で区切られた連続するタスクの区間(run)ごとに独立してソートする。
-- テキスト行自体は元の位置にそのまま残る。
local function sort_items(items)
	local result = {}
	local run = {}

	local function flush_run()
		if #run == 0 then
			return
		end
		for i, item in ipairs(run) do
			item.original_index = i
		end
		table.sort(run, compare_tasks)
		for _, item in ipairs(run) do
			table.insert(result, { type = "task", task = item.task })
		end
		run = {}
	end

	for _, item in ipairs(items) do
		if item.type == "task" then
			table.insert(run, item)
		else
			flush_run()
			table.insert(result, item)
		end
	end
	flush_run()

	return result
end

-- セクション内のタスクをソートする
-- 入力/出力: { type="task"|"text", ... } のフラット配列
function M.sort_section_tasks(items)
	return sort_items(items or {})
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
