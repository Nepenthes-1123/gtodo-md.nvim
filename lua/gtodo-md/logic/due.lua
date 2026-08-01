local M = {}
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")

local mem_last_notify_time = 0
local mem_last_notify_content = ""

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
--
-- 既知の残存リスク(R5-3、受容済み):
-- 複数のNeovimインスタンスが同じ data_dir を同時に開いている場合、
-- 他インスタンスの未保存(dirty)バッファの内容はこのインスタンスから
-- 関知できない。あるインスタンス(A)が todo.md を未保存のまま長時間
-- 開いている間に、別インスタンス(B)がこの関数でinbox→todoの昇格を
-- 行いディスクに反映した後、(A)がその変更を知らないまま自分の
-- (古い)バッファ内容をどこかのタイミングでコミットすると、
-- (B)が昇格させたタスクが消失する可能性がある。
-- move_completed_tasks(daily.lua の日付ゲート付きロールオーバー)は
-- 「1日1回」の制御により同種の重複は起きないが、check_dues は
-- イベント駆動で日付ゲートを持たないため、この経路にのみ残る。
-- 発生には複数インスタンス同時使用・長時間の未保存編集・タイミングの
-- 衝突が重なる必要があり、低確率と判断して許容している。
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
		local sec_items = inbox_data.sections["default"]
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
		inbox_data.sections["default"] = remaining
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
		todo_data.sections[config.sections.TODAY] = {}
		table.insert(todo_data.section_order, 1, config.sections.TODAY)
	end

	for _, item in ipairs(items_to_move) do
		table.insert(todo_data.sections[config.sections.TODAY], item)
		moved_count = moved_count + 1
		todo_changed = true
	end

	if #future_items_to_move > 0 then
		if not todo_data.sections[config.sections.WAITING] then
			todo_data.sections[config.sections.WAITING] = {}
		end
		for _, item in ipairs(future_items_to_move) do
			table.insert(todo_data.sections[config.sections.WAITING], item)
			moved_count = moved_count + 1
			todo_changed = true
		end
	end

	for _, from_sec in ipairs({ config.sections.NEXT, config.sections.SOMEDAY, config.sections.WAITING }) do
		if todo_data.sections[from_sec] then
			local sec_items = todo_data.sections[from_sec]
			local remaining_items = {}
			for _, item in ipairs(sec_items) do
				if item.type == "task" and item.task.status ~= "x" and item.task.due and item.task.due <= today then
					item.task.wait = nil -- 自動移動時も wait: を剥がす
					table.insert(todo_data.sections[config.sections.TODAY], item)
					moved_count = moved_count + 1
					todo_changed = true
				else
					table.insert(remaining_items, item)
				end
			end
			todo_data.sections[from_sec] = remaining_items
		end
	end

	if todo_changed then
		io_mod.write_todo_file(todo_path, todo_data)
		vim.notify(string.format("Moved %d tasks to Today due to deadline.", moved_count), vim.log.levels.INFO)
	end

	return todo_changed
end

return M
