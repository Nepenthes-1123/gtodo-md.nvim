local M = {}
local config = require('gtodo-md.config')
local io_mod = require('gtodo-md.io')

local uv = vim.uv or vim.loop

local waiting_timer = nil

-- Waitingタスクの期日チェックと通知
function M.check_waiting_tasks()
  local data_dir = config.get("data_dir")
  local todo_path = data_dir .. "/todo.md"
  
  if vim.fn.filereadable(todo_path) == 0 then return end
  
  local todo_data = io_mod.read_todo_file(todo_path)
  local waiting_tasks = todo_data.sections[config.sections.WAITING]
  if not waiting_tasks or #waiting_tasks == 0 then return end
  
  local today = os.time()
  local warning_days = config.get("waiting_warning_days")
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

local function should_skip_timer()
  local mode = vim.fn.mode()
  if mode ~= "n" then
    local cur_buf = vim.api.nvim_get_current_buf()
    local bname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur_buf), ":t")
    if bname == "inbox.md" or bname == "todo.md" or bname == "done.md" then
      return true
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local bname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
      if bname == "inbox.md" or bname == "todo.md" or bname == "done.md" then
        return true
      end
    end
  end
  return false
end

-- Waiting監視タイマーの開始
function M.start_waiting_timer()
  local enabled = config.get("enable_waiting_warning")
  if not enabled then return end
  if waiting_timer then return end
  
  -- 起動時に一度即時チェックを実行 (遅延ロードや起動シーケンスと競合しないよう非同期にスケジューリング)
  vim.schedule(function()
    if not should_skip_timer() then
      M.check_waiting_tasks()
    end
  end)
  
  local interval = config.get("waiting_warning_interval") * 1000
  waiting_timer = uv.new_timer()
  waiting_timer:start(interval, interval, vim.schedule_wrap(function()
    if not should_skip_timer() then
      M.check_waiting_tasks()
    end
  end))
end

local rollover_timer = nil

function M.start_daily_rollover_timer()
  if rollover_timer then return end
  
  -- 60秒に1回、超軽量な日付変更チェックを走らせる
  local interval = 60 * 1000
  rollover_timer = uv.new_timer()
  rollover_timer:start(interval, interval, vim.schedule_wrap(function()
    if not should_skip_timer() then
      require('gtodo-md').check_daily_rollover()
    end
  end))
end

function M.stop_timers()
  if waiting_timer then
    waiting_timer:stop()
    waiting_timer:close()
    waiting_timer = nil
  end
  if rollover_timer then
    rollover_timer:stop()
    rollover_timer:close()
    rollover_timer = nil
  end
end

return M
