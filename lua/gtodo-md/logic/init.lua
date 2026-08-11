local M = {}

M.sort_section_tasks = require("gtodo-md.logic.sort").sort_section_tasks
M.sort_todo_file = require("gtodo-md.logic.sort").sort_todo_file
M.check_dues = require("gtodo-md.logic.due").check_dues
M.append_to_history = require("gtodo-md.logic.history").append_to_history
M.move_completed_tasks = require("gtodo-md.logic.completion").move_completed_tasks
M.append_then_remove = require("gtodo-md.logic.write_pair").append_then_remove

-- check_dues を実行し、(always_sort が真、または check_dues 自身が変化を
-- 起こした)場合のみ sort_todo_file を呼ぶ。呼び出し元が既に排他ロックを
-- 保持している前提で、ここではロックを取得しない — init.lua の
-- check_dues_and_sort ヘルパー(自前でロックを取る)と daily.lua の
-- check_daily_rollover(move_completed_tasksと合わせて1つのロック内で
-- 呼ぶ)の両方から共有される。
-- 返り値: check_dues が変化を起こしたかどうか
function M.check_dues_and_maybe_sort(inbox_path, todo_path, always_sort)
	local changed = M.check_dues(inbox_path, todo_path)
	if always_sort or changed then
		M.sort_todo_file(todo_path)
	end
	return changed
end

-- check_dues を実行するが、sort_todo_file を呼ぶかどうかは check_dues自身が
-- 変化を起こしたかを見ず、呼び出し元が渡した条件だけで決める
-- (check_dues_and_maybe_sort とは判定基準が異なる)。handle_buf_enter が
-- 「todo.mdを開いているかどうか」だけでsortの要否を決めたい場合に使う。
-- 呼び出し元が既に排他ロックを保持している前提で、ここではロックを取得しない。
function M.check_dues_and_sort_when_requested(inbox_path, todo_path, should_sort)
	M.check_dues(inbox_path, todo_path)
	if should_sort then
		M.sort_todo_file(todo_path)
	end
end

return M
