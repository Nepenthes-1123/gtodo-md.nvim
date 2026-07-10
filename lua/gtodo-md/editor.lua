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

-- BUG-5/BUG-15対応: todo.md内のタスク検索・更新の共通ヘルパー
-- action_fn(todo_data, section, idx) を受け取って変更を加える
-- タスクが見つかれば true、見つからなければ false を返す
local function update_task_in_todo(task, section, action_fn)
  local todo_path = config.get("data_dir") .. "/todo.md"
  local todo_data = io_mod.read_todo_file(todo_path)

  if not todo_data.sections[section] then return false end

  local found_idx = nil
  for i, item in ipairs(todo_data.sections[section]) do
    -- BUG-19対応: original_lineを使わず content+created で同定
    -- (split後に original_line が古くなる問題を回避)
    if item.type == "task"
      and item.task.content == task.content
      and item.task.created == task.created then
      found_idx = i
      break
    end
  end

  if not found_idx then return false end

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
    local ok = update_task_in_todo(task, current_sec, function(todo_data, section, idx)
      local t = todo_data.sections[section][idx].task
      if is_completed then
        t.status = " "
        t.completed_at = nil
      else
        t.status = "x"
        t.completed_at = today
      end
      todo_data.sections[section] = logic_mod.sort_section_tasks(todo_data.sections[section])
    end)
    if not ok then
      vim.notify("Task not found in todo.md.", vim.log.levels.WARN)
    end
  else
    if is_completed then
      task.status = " "
      task.completed_at = nil
    else
      task.status = "x"
      task.completed_at = today
    end
    local newline = task_mod.serialize(task)
    local buf = vim.api.nvim_get_current_buf()
    local set_ok, err = pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, { newline })
    if not set_ok then
      vim.notify("Failed to update task line: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("write") end)
  end
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
    local buf = vim.api.nvim_get_current_buf()
    local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, {})
    if not ok then
      vim.notify("Failed to remove task from inbox: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("write") end)

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

    -- BUG-15対応: update_task_in_todo の戻り値を確認してから notify
    local moved = false
    local ok = update_task_in_todo(task, current_sec, function(todo_data, section, idx)
      table.remove(todo_data.sections[section], idx)

      if not todo_data.sections[target_section] then
        todo_data.sections[target_section] = {}
        local has_sec = false
        for _, s in ipairs(todo_data.section_order) do
          if s == target_section then has_sec = true; break end
        end
        if not has_sec then
          table.insert(todo_data.section_order, target_section)
        end
      end

      table.insert(todo_data.sections[target_section], { type = "task", task = task })
      todo_data.sections[section] = logic_mod.sort_section_tasks(todo_data.sections[section] or {})
      todo_data.sections[target_section] = logic_mod.sort_section_tasks(todo_data.sections[target_section])
      moved = true
    end)

    if ok and moved then
      vim.notify(string.format("Moved task to [%s]", target_section), vim.log.levels.INFO)
    elseif not ok then
      vim.notify("Task not found in current section.", vim.log.levels.WARN)
    end
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
    local ok = update_task_in_todo(task, current_sec, function(todo_data, section, idx)
      table.remove(todo_data.sections[section], idx)
    end)
    if not ok then
      vim.notify("Task not found in todo.md.", vim.log.levels.WARN)
      return
    end
  else
    local buf = vim.api.nvim_get_current_buf()
    local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, {})
    if not ok then
      vim.notify("Failed to remove task line: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("write") end)
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
