local M = {}
local config = require('gtodo_md.config')
local file_mod = require('gtodo_md.file')

local uv = vim.uv or vim.loop

local date_timer = nil
local waiting_timer = nil

-- 日付変更検知と自動移動
function M.check_date_change()
  local last_date = require('gtodo_md.utils').read_last_opened()
  local today = os.date("%Y-%m-%d")
  
  if not last_date then
    require('gtodo_md.utils').write_last_opened(today)
    return false
  end
  
  if last_date ~= today then
    local data_dir = config.options.data_dir
    local inbox_path = data_dir .. "/inbox.md"
    local todo_path = data_dir .. "/todo.md"
    local done_path = data_dir .. "/done.md"
    
    file_mod.move_completed_tasks(inbox_path, todo_path, done_path)
    require('gtodo_md.utils').write_last_opened(today)
    return true
  end
  
  return false
end

-- 日付変更監視タイマーを開始
function M.start_date_timer()
  if date_timer then return end
  
  -- 1分おきにチェックする
  date_timer = uv.new_timer()
  date_timer:start(60000, 60000, vim.schedule_wrap(function()
    M.check_date_change()
  end))
end

-- Waitingタスクの期日チェックと通知
function M.check_waiting_tasks()
  local data_dir = config.options.data_dir
  local todo_path = data_dir .. "/todo.md"
  
  if vim.fn.filereadable(todo_path) == 0 then return end
  
  local todo_data = file_mod.read_todo_file(todo_path)
  local waiting_tasks = todo_data.sections["Waiting"]
  if not waiting_tasks or #waiting_tasks == 0 then return end
  
  local today = os.time()
  local two_days_later = today + 2 * 24 * 3600
  local limit_str = os.date("%Y-%m-%d", two_days_later)
  
  local notify_list = {}
  for _, item in ipairs(waiting_tasks) do
    if item.type == "task" and item.task.status ~= "x" and item.task.due and item.task.due ~= "" then
      if item.task.due <= limit_str then
        table.insert(notify_list, string.format("- %s (due: %s)", item.task.content, item.task.due))
      end
    end
  end
  
  if #notify_list > 0 then
    vim.notify("Waiting tasks due soon:\n" .. table.concat(notify_list, "\n"), vim.log.levels.WARN)
  end
end

-- Waiting監視タイマーの開始 (1時間おき)
function M.start_waiting_timer()
  if waiting_timer then return end
  
  waiting_timer = uv.new_timer()
  waiting_timer:start(3600000, 3600000, vim.schedule_wrap(function()
    M.check_waiting_tasks()
  end))
end

function M.stop_timers()
  if date_timer then
    date_timer:stop()
    date_timer:close()
    date_timer = nil
  end
  if waiting_timer then
    waiting_timer:stop()
    waiting_timer:close()
    waiting_timer = nil
  end
end

return M
