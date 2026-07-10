local M = {}

-- 日付文字列 (YYYY-MM-DD) → os.time に変換する
function M.date_to_time(date_str)
  return os.time({
    year  = tonumber(date_str:sub(1, 4)),
    month = tonumber(date_str:sub(6, 7)),
    day   = tonumber(date_str:sub(9, 10)),
    hour = 0, min = 0, sec = 0,
  })
end

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

local function get_state_path()
  local config = require('gtodo-md.config')
  local data_dir = config.get("data_dir")
  return data_dir .. "/.state.json"
end

local function read_state()
  local path = get_state_path()
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*all")
  f:close()
  if not content or content == "" then return {} end
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local function write_state(data)
  local path = get_state_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local tmp_path = path .. ".tmp"
  local f = io.open(tmp_path, "w")
  if f then
    local ok, content = pcall(vim.json.encode, data)
    if ok then
      f:write(content)
    end
    f:close()
    if vim.fn.rename(tmp_path, path) ~= 0 then
      os.remove(tmp_path)
    end
  end
end

function M.read_last_opened()
  local state = read_state()
  return state.last_opened
end

function M.write_last_opened(date_str)
  local state = read_state()
  state.last_opened = date_str
  write_state(state)
end

function M.read_notify_state()
  local state = read_state()
  return state.last_notify_time or 0, state.last_notify_content or ""
end

function M.write_notify_state(time, content)
  local state = read_state()
  state.last_notify_time = time
  state.last_notify_content = content
  write_state(state)
end

function M.is_todo_line(line)
  if type(line) ~= "string" then return false end
  return line:match("%[%s%]") ~= nil
end

function M.is_done_line(line)
  if type(line) ~= "string" then return false end
  return line:match("%[x%]") ~= nil or line:match("%[X%]") ~= nil
end

function M.create_project_file(project_tag)
  local data_dir = require('gtodo-md.config').options.data_dir
  local projects_dir = data_dir .. "/projects"
  
  if vim.fn.isdirectory(projects_dir) == 0 then
    vim.fn.mkdir(projects_dir, "p")
  end
  
  local proj_file = string.format("%s/%s.md", projects_dir, project_tag)
  if vim.fn.filereadable(proj_file) == 0 then
    local today = os.date("%Y-%m-%d")
    local template = {
      "---",
      "title:                 ",
      "tag: " .. project_tag,
      "created: " .. today,
      "due:                   ",
      "status: active         ",
      "members: []            ",
      "---",
      "",
      "## Overview",
      "",
      "## Notes",
      "",
      "## Reference",
      ""
    }
    
    local tmp_file = proj_file .. ".tmp"
    local ok, f = pcall(io.open, tmp_file, "w")
    if ok and f then
      for _, l in ipairs(template) do
        f:write(l .. "\n")
      end
      f:close()
      if vim.fn.rename(tmp_file, proj_file) == 0 then
        vim.notify("Created new project file: " .. project_tag, vim.log.levels.INFO)
        return true
      else
        os.remove(tmp_file)
        vim.notify("Failed to create project file atomically: " .. proj_file, vim.log.levels.ERROR)
        return false
      end
    else
      vim.notify("Failed to create project file: " .. proj_file, vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

return M
