local M = {}
local task_mod = require('gtodo-md.task')
local config = require('gtodo-md.config')
local io_mod = require('gtodo-md.io')
local logic_mod = require('gtodo-md.logic')

-- カーソル行がタスクか判定
function M.get_current_task()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  if not line then return nil end
  local task = task_mod.parse(line)
  return task, row, line
end

-- Shared helper: load todo.md, locate `task` in `section` by identity
-- (content + created), then call action_fn(todo_data, section, found_idx).
-- action_fn is responsible for mutating todo_data; the helper saves afterward.
-- Returns true if the task was found and action_fn was called, false otherwise.
local function update_task_in_todo(task, section, action_fn)
  local todo_path = config.get("data_dir") .. "/todo.md"
  local todo_data = io_mod.read_todo_file(todo_path)

  if not todo_data.sections[section] then
    return false
  end

  local found_idx = nil
  for i, item in ipairs(todo_data.sections[section]) do
    if item.type == "task"
        and item.task.content == task.content
        and item.task.created == task.created then
      found_idx = i
      break
    end
  end

  if not found_idx then
    return false
  end

  action_fn(todo_data, section, found_idx)
  io_mod.write_todo_file(todo_path, todo_data)
  return true
end

-- 完了トグル
function M.toggle_complete()
  local task, row = M.get_current_task()
  if not task then
    vim.notify("Not on a task line.", vim.log.levels.WARN)
    return
  end

  local bufname = vim.api.nvim_buf_get_name(0)
  local filename = vim.fn.fnamemodify(bufname, ":t")
  local today = os.date("%Y-%m-%d")
  local is_completed = (task.status == "x")

  if filename == "todo.md" then
    local current_sec = M.get_current_section()
    update_task_in_todo(task, current_sec, function(todo_data, section, idx)
      local item = todo_data.sections[section][idx]
      if is_completed then
        item.task.status = " "
        item.task.completed_at = nil
      else
        item.task.status = "x"
        item.task.completed_at = today
      end
      todo_data.sections[section] = logic_mod.sort_section_tasks(todo_data.sections[section])
    end)
  else
    if is_completed then
      task.status = " "
      task.completed_at = nil
    else
      task.status = "x"
      task.completed_at = today
    end
    local newline = task_mod.serialize(task)
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, { newline })
    vim.cmd("silent! write")
  end
end

-- カーソル位置のセクションを特定する
function M.get_current_section()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  for i = #lines, 1, -1 do
    local sec_name = lines[i]:match("^##%s+(.*)$")
    if sec_name then
      return vim.trim(sec_name)
    end
  end
  return "default"
end

-- タスクのセクション移動
function M.move_current_task_to(target_section)
  local task, row = M.get_current_task()
  if not task then
    vim.notify("Not on a task line.", vim.log.levels.WARN)
    return
  end

  local bufname = vim.api.nvim_buf_get_name(0)
  local filename = vim.fn.fnamemodify(bufname, ":t")

  local data_dir = config.get("data_dir")
  local inbox_path = data_dir .. "/inbox.md"
  local todo_path = data_dir .. "/todo.md"

  if filename == "inbox.md" then
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, {})
    vim.cmd("silent! write")

    local todo_data = io_mod.read_todo_file(todo_path)
    if #todo_data.section_order == 0 then
      todo_data.section_order = { config.sections.TODAY, config.sections.NEXT, config.sections.WAITING, config.sections.SOMEDAY }
    end
    if not todo_data.sections[target_section] then
      todo_data.sections[target_section] = {}
    end
    table.insert(todo_data.sections[target_section], { type = "task", task = task })
    todo_data.sections[target_section] = logic_mod.sort_section_tasks(todo_data.sections[target_section])
    io_mod.write_todo_file(todo_path, todo_data)
    vim.notify(string.format("Moved task to todo.md [%s]", target_section), vim.log.levels.INFO)

  elseif filename == "todo.md" then
    local current_sec = M.get_current_section()
    if current_sec == target_section then
      vim.notify("Already in " .. target_section, vim.log.levels.INFO)
      return
    end

    update_task_in_todo(task, current_sec, function(todo_data, section, idx)
      table.remove(todo_data.sections[section], idx)

      if not todo_data.sections[target_section] then
        todo_data.sections[target_section] = {}
        local has_sec = false
        for _, s in ipairs(todo_data.section_order) do
          if s == target_section then has_sec = true break end
        end
        if not has_sec then
          table.insert(todo_data.section_order, target_section)
        end
      end

      table.insert(todo_data.sections[target_section], { type = "task", task = task })
      todo_data.sections[section] = logic_mod.sort_section_tasks(todo_data.sections[section] or {})
      todo_data.sections[target_section] = logic_mod.sort_section_tasks(todo_data.sections[target_section])
    end)
    vim.notify(string.format("Moved task to [%s]", target_section), vim.log.levels.INFO)
  end
end

-- タスクのキャンセル
function M.cancel_current_task()
  local task, row = M.get_current_task()
  if not task then
    vim.notify("Not on a task line.", vim.log.levels.WARN)
    return
  end

  local bufname = vim.api.nvim_buf_get_name(0)
  local filename = vim.fn.fnamemodify(bufname, ":t")

  if filename == "todo.md" then
    local current_sec = M.get_current_section()
    update_task_in_todo(task, current_sec, function(todo_data, section, idx)
      table.remove(todo_data.sections[section], idx)
    end)
  else
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, {})
    vim.cmd("silent! write")
  end

  local current_month = os.date("%Y-%m")
  local data_dir = config.get("data_dir")
  local cancelled_path = data_dir .. "/cancelled.md"

  logic_mod.append_to_history(cancelled_path, "Cancelled", current_month, { task })
  vim.notify("Task cancelled and moved to cancelled.md", vim.log.levels.INFO)
end

function M.split_current_task()
  require('gtodo-md.split').split_current_task()
end

return M
