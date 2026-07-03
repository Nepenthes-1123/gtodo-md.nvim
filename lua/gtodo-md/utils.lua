local M = {}

function M.parse_due_date(str)
  if not str or str == "" then return nil end
  str = vim.trim(str):lower()
  
  local today = os.time()
  
  -- today, tomorrow, etc.
  if str == "today" or str == "t" then
    return os.date("%Y-%m-%d", today)
  elseif str == "tomorrow" or str == "tm" then
    return os.date("%Y-%m-%d", today + 24*3600)
  end
  
  -- relative: +Nd, +Nw, +Nm, +Ny
  local num, unit = str:match("^%+(%d+)([dwmy]?)$")
  if num then
    num = tonumber(num)
    if unit == "" or unit == "d" then
      return os.date("%Y-%m-%d", today + num * 24*3600)
    elseif unit == "w" then
      return os.date("%Y-%m-%d", today + num * 7 * 24*3600)
    elseif unit == "m" then
      return os.date("%Y-%m-%d", today + num * 30 * 24*3600)
    elseif unit == "y" then
      return os.date("%Y-%m-%d", today + num * 365 * 24*3600)
    end
  end
  
  -- Day of week: mon, tue, wed, thu, fri, sat, sun
  local wdays = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 }
  local wday_num = wdays[str:sub(1, 3)]
  if wday_num then
    local current_wday = tonumber(os.date("%w", today)) + 1 -- 1: Sun, 7: Sat
    local diff = wday_num - current_wday
    if diff <= 0 then diff = diff + 7 end -- next week
    return os.date("%Y-%m-%d", today + diff * 24*3600)
  end
  
  -- YYYY-MM-DD, YYYY/MM/DD, YYYYMMDD
  local y, m, d = str:match("^(%d%d%d%d)[%-/](%d%d?)[%-/](%d%d?)$")
  if not y then
    y, m, d = str:match("^(%d%d%d%d)(%d%d)(%d%d)$")
  end
  
  -- MM-DD, MM/DD
  if not y then
    m, d = str:match("^(%d%d?)[%-/](%d%d?)$")
    if m then
      y = os.date("%Y", today)
    end
  end
  
  if y and m and d then
    return string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
  end
  
  if str:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return str
  end
  
  return nil
end

function M.get_last_opened_path()
  return vim.fn.stdpath("data") .. "/todo_last_opened"
end

function M.read_last_opened()
  local path = M.get_last_opened_path()
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return vim.trim(content)
end

function M.write_last_opened(date_str)
  local path = M.get_last_opened_path()
  local f = io.open(path, "w")
  if f then
    f:write(date_str)
    f:close()
  end
end

return M
