local M = {}
local config = require('gtodo-md.config')
local file_mod = require('gtodo-md.file')

local uv = vim.uv or vim.loop

local waiting_timer = nil

-- Waitingタスクの期日チェックと通知
function M.check_waiting_tasks()
  local data_dir = config.options.data_dir
  local todo_path = data_dir .. "/todo.md"
  
  if vim.fn.filereadable(todo_path) == 0 then return end
  
  local todo_data = file_mod.read_todo_file(todo_path)
  local waiting_tasks = todo_data.sections["Waiting"]
  if not waiting_tasks or #waiting_tasks == 0 then return end
  
  local today = os.time()
  local warning_days = config.options.waiting_warning_days or 2
  local two_days_later = today + warning_days * 24 * 3600
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

-- Waiting監視タイマーの開始
function M.start_waiting_timer()
  local enabled = config.options.enable_waiting_warning
  if enabled == nil then enabled = true end
  if not enabled then return end
  if waiting_timer then return end
  
  -- 起動時に一度即時チェックを実行 (遅延ロードや起動シーケンスと競合しないよう非同期にスケジューリング)
  vim.schedule(function()
    M.check_waiting_tasks()
  end)
  
  local interval = (config.options.waiting_warning_interval or 3600) * 1000
  waiting_timer = uv.new_timer()
  waiting_timer:start(interval, interval, vim.schedule_wrap(function()
    M.check_waiting_tasks()
  end))
end

function M.stop_timers()
  if waiting_timer then
    waiting_timer:stop()
    waiting_timer:close()
    waiting_timer = nil
  end
end

return M
