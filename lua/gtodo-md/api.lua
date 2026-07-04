local M = {}
local config = require('gtodo-md.config')

local cache = {
  todo_mtime = 0,
  inbox_mtime = 0,
  stats = { today = 0, inbox = 0 }
}

-- 高速にタスク数をカウントするAPI (Lualine等用)
function M.get_stats()
  local data_dir = config.get("data_dir")
  if not data_dir then return cache.stats end
  
  local todo_path = data_dir .. "/todo.md"
  local inbox_path = data_dir .. "/inbox.md"
  
  local todo_mtime = vim.fn.getftime(todo_path)
  local inbox_mtime = vim.fn.getftime(inbox_path)
  
  local needs_update = false
  if todo_mtime ~= cache.todo_mtime or inbox_mtime ~= cache.inbox_mtime then
    needs_update = true
  end
  
  if needs_update then
    local stats = { today = 0, inbox = 0 }
    
    -- todo.md から Today の未完了タスク数を高速カウント
    if vim.fn.filereadable(todo_path) == 1 then
      local f = io.open(todo_path, "r")
      if f then
        local in_today = false
        for line in f:lines() do
          if line:match("^## ") then
            if line:match("^## Today") then
              in_today = true
            else
              in_today = false
            end
          end
          if in_today and line:match("^%s*-%s*%[ %]") then
            stats.today = stats.today + 1
          end
        end
        f:close()
      end
    end
    
    -- inbox.md から Inbox の未完了タスク数を高速カウント
    if vim.fn.filereadable(inbox_path) == 1 then
      local f = io.open(inbox_path, "r")
      if f then
        for line in f:lines() do
          if line:match("^%s*-%s*%[ %]") then
            stats.inbox = stats.inbox + 1
          end
        end
        f:close()
      end
    end
    
    cache.todo_mtime = todo_mtime
    cache.inbox_mtime = inbox_mtime
    cache.stats = stats
  end
  
  return cache.stats
end

return M
