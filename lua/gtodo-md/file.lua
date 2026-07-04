local M = {}
local task_mod = require('gtodo-md.task')
local config = require('gtodo-md.config')

-- メモリ管理用 (due_notification_persist = false の場合)
local mem_last_notify_time = 0
local mem_last_notify_content = ""

-- 指定されたパスのバッファが存在し、ロードされているか確認
local function get_buf_by_name(path)
  local realpath = vim.fn.fnamemodify(path, ":p")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local bufname = vim.api.nvim_buf_get_name(buf)
      if vim.fn.fnamemodify(bufname, ":p") == realpath then
        return buf
      end
    end
  end
  return nil
end

-- ファイルまたはバッファから行リストを読み込む
function M.read_lines(path)
  local buf = get_buf_by_name(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    local lines = {}
    local f = io.open(path, "r")
    if not f then return lines end
    for line in f:lines() do
      table.insert(lines, line)
    end
    f:close()
    return lines
  end
end

-- ファイルまたはバッファに行リストを書き込む
function M.write_lines(path, lines)
  local buf = get_buf_by_name(path)
  if buf then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! write")
    end)
  else
    local tmp_path = path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if f then
      for _, line in ipairs(lines) do
        f:write(line .. "\n")
      end
      f:close()
      
      local success = (vim.fn.rename(tmp_path, path) == 0)
      if not success then
        os.remove(tmp_path)
        vim.notify("Failed to write file atomically", vim.log.levels.ERROR)
      end
    end
  end
end

-- 指定ファイルをパースして、セクションごとの行のリストにする
function M.read_todo_file(filepath)
  local lines = M.read_lines(filepath)
  if #lines == 0 then
    return { sections = {}, section_order = {}, header = {} }
  end
  return M.parse_markdown(lines)
end

function M.parse_markdown(lines)
  local data = {
    header = {},
    sections = {},
    section_order = {},
  }
  
  local current_section = "default"
  data.sections[current_section] = {}
  
  local header_done = false
  
  for _, line in ipairs(lines) do
    local sec_name = line:match("^##%s+(.*)$")
    local task = task_mod.parse(line)
    
    if sec_name then
      sec_name = vim.trim(sec_name)
      current_section = sec_name
      if not data.sections[current_section] then
        data.sections[current_section] = {}
        table.insert(data.section_order, current_section)
      end
      header_done = true
    elseif task then
      header_done = true
    end
    
    if not header_done then
      table.insert(data.header, line)
    else
      if not sec_name then
        if task then
          table.insert(data.sections[current_section], { type = "task", task = task, line = line })
        else
          table.insert(data.sections[current_section], { type = "text", line = line })
        end
      end
    end
  end
  
  return data
end

-- パースしたデータを書き戻す
function M.write_todo_file(filepath, data)
  local lines = {}
  
  for _, l in ipairs(data.header) do
    table.insert(lines, l)
  end
  
  if data.sections["default"] then
    for _, item in ipairs(data.sections["default"]) do
      if item.type == "task" then
        table.insert(lines, task_mod.serialize(item.task))
      else
        table.insert(lines, item.line)
      end
    end
  end
  
  for _, sec in ipairs(data.section_order) do
    if #lines > 0 and lines[#lines] ~= "" then
      table.insert(lines, "")
    end
    table.insert(lines, "## " .. sec)
    
    local items = data.sections[sec] or {}
    for _, item in ipairs(items) do
      if item.type == "task" then
        table.insert(lines, task_mod.serialize(item.task))
      else
        table.insert(lines, item.line)
      end
    end
  end
  
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  table.insert(lines, "")
  
  M.write_lines(filepath, lines)
  return true
end

-- セクション内のタスクをソートする
function M.sort_section_tasks(items)
  local tasks = {}
  for i, item in ipairs(items) do
    if item.type == "task" then
      item.original_index = i
      table.insert(tasks, item)
    end
  end
  
  table.sort(tasks, function(a, b)
    local t_a = a.task
    local t_b = b.task
    
    -- 1. [x] 付きは最末尾に固定
    local done_a = (t_a.status == "x")
    local done_b = (t_b.status == "x")
    if done_a ~= done_b then
      return done_b
    end
    
    -- 2. dueあり優先、dueなしは末尾
    local has_due_a = (t_a.due ~= nil and t_a.due ~= "")
    local has_due_b = (t_b.due ~= nil and t_b.due ~= "")
    if has_due_a ~= has_due_b then
      return has_due_a
    end
    
    if has_due_a and has_due_b then
      if t_a.due ~= t_b.due then
        return t_a.due < t_b.due
      end
    end
    
    -- 3. stable sort
    return a.original_index < b.original_index
  end)
  
  local new_items = {}
  for _, t in ipairs(tasks) do
    table.insert(new_items, { type = "task", task = t.task })
  end
  
  for _, item in ipairs(items) do
    if item.type == "text" and vim.trim(item.line) ~= "" then
      table.insert(new_items, item)
    end
  end
  
  return new_items
end

-- todo.mdをソートする
function M.sort_todo_file(filepath)
  local data = M.read_todo_file(filepath)
  for _, sec in ipairs(data.section_order) do
    data.sections[sec] = M.sort_section_tasks(data.sections[sec])
  end
  M.write_todo_file(filepath, data)
end

local function get_last_notify_state(persist)
  if persist then
    local utils = require('gtodo-md.utils')
    return utils.read_notify_state()
  else
    return mem_last_notify_time, mem_last_notify_content
  end
end

local function set_last_notify_state(persist, time, content)
  if persist then
    local utils = require('gtodo-md.utils')
    utils.write_notify_state(time, content)
  else
    mem_last_notify_time = time
    mem_last_notify_content = content
  end
end

-- dueチェック・自動移動
function M.check_dues(inbox_path, todo_path)
  local today = os.date("%Y-%m-%d")
  local moved_count = 0
  
  -- 1. inbox.md の dueチェック (警告通知のみ)
  local inbox_data = M.read_todo_file(inbox_path)
  local inbox_warnings = {}
  
  if inbox_data.sections["default"] then
    for _, item in ipairs(inbox_data.sections["default"]) do
      if item.type == "task" and item.task.status ~= "x" and item.task.due then
        if item.task.due <= today then
          table.insert(inbox_warnings, string.format("Inbox: %s (due: %s)", item.task.content, item.task.due))
        end
      end
    end
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

  -- 2. todo.md の dueチェック (Next/Someday -> Today)
  local todo_data = M.read_todo_file(todo_path)
  local todo_changed = false
  
  if not todo_data.sections["Today"] then
    todo_data.sections["Today"] = {}
    table.insert(todo_data.section_order, 1, "Today")
  end
  
  for _, from_sec in ipairs({ "Next", "Someday" }) do
    if todo_data.sections[from_sec] then
      local remaining_items = {}
      for _, item in ipairs(todo_data.sections[from_sec]) do
        if item.type == "task" and item.task.status ~= "x" and item.task.due and item.task.due <= today then
          table.insert(todo_data.sections["Today"], item)
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
    M.write_todo_file(todo_path, todo_data)
    vim.notify(string.format("Moved %d tasks to Today due to deadline.", moved_count), vim.log.levels.INFO)
  end
  
  return todo_changed
end

-- 履歴ファイル (done.md / cancelled.md) へタスクを追記する
-- move_completed_tasks と cancel_current_task の両方から使用する
local function append_to_history(filepath, header_title, section_name, tasks)
  local lines = {}
  local file_exists = vim.fn.filereadable(filepath) == 1

  if file_exists then
    local f = io.open(filepath, "r")
    if f then
      for line in f:lines() do
        table.insert(lines, line)
      end
      f:close()
    end
  else
    table.insert(lines, "# " .. header_title)
    table.insert(lines, "")
  end

  -- セクションがすでに存在するかチェック
  local has_section = false
  for _, line in ipairs(lines) do
    if line == "## " .. section_name then
      has_section = true
      break
    end
  end

  if not has_section then
    if #lines > 0 and lines[#lines] ~= "" then
      table.insert(lines, "")
    end
    table.insert(lines, "## " .. section_name)
  end

  for _, t in ipairs(tasks) do
    table.insert(lines, task_mod.serialize(t))
  end

  M.write_lines(filepath, lines)
end

-- 完了タスクを done.md へ移動
function M.move_completed_tasks(inbox_path, todo_path, done_path)
  local today = os.date("%Y-%m-%d")
  local current_month = os.date("%Y-%m")
  local moved_tasks = {}

  -- 1. inbox.md から完了タスクを抽出
  local inbox_data = M.read_todo_file(inbox_path)
  local inbox_changed = false
  if inbox_data.sections["default"] then
    local remaining = {}
    for _, item in ipairs(inbox_data.sections["default"]) do
      if item.type == "task" and item.task.status == "x" then
        table.insert(moved_tasks, { task = item.task, from = "inbox" })
        inbox_changed = true
      else
        table.insert(remaining, item)
      end
    end
    inbox_data.sections["default"] = remaining
  end
  if inbox_changed then
    M.write_todo_file(inbox_path, inbox_data)
  end

  -- 2. todo.md から完了タスクを抽出
  local todo_data = M.read_todo_file(todo_path)
  local todo_changed = false
  for _, sec in ipairs({ "Today", "Next", "Waiting", "Someday" }) do
    if todo_data.sections[sec] then
      local remaining = {}
      for _, item in ipairs(todo_data.sections[sec]) do
        if item.type == "task" and item.task.status == "x" then
          table.insert(moved_tasks, { task = item.task, from = sec:lower() })
          todo_changed = true
        else
          table.insert(remaining, item)
        end
      end
      todo_data.sections[sec] = remaining
    end
  end
  if todo_changed then
    M.write_todo_file(todo_path, todo_data)
  end

  if #moved_tasks == 0 then
    return false
  end

  -- 3. done.md へ追加
  local done_tasks = {}
  for _, entry in ipairs(moved_tasks) do
    local t = entry.task
    local comp_date = t.completed_at or today
    t.completed_at = nil
    t.done = comp_date
    t.from = entry.from
    table.insert(done_tasks, t)
  end

  append_to_history(done_path, "Done", current_month, done_tasks)
  vim.notify(string.format("Moved %d completed tasks to done.md", #moved_tasks), vim.log.levels.INFO)
  return true
end


-- カーソル行がタスクか判定
function M.get_current_task()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  if not line then return nil end
  local task = task_mod.parse(line)
  return task, row, line
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
    local todo_path = config.get("data_dir") .. "/todo.md"
    local todo_data = M.read_todo_file(todo_path)
    local current_sec = M.get_current_section()
    
    if todo_data.sections[current_sec] then
      for _, item in ipairs(todo_data.sections[current_sec]) do
        if item.type == "task" and item.task.content == task.content and item.task.created == task.created then
          if is_completed then
            item.task.status = " "
            item.task.completed_at = nil
          else
            item.task.status = "x"
            item.task.completed_at = today
          end
          break
        end
      end
      todo_data.sections[current_sec] = M.sort_section_tasks(todo_data.sections[current_sec])
    end
    M.write_todo_file(todo_path, todo_data)
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
    
    local todo_data = M.read_todo_file(todo_path)
    if #todo_data.section_order == 0 then
      todo_data.section_order = { "Today", "Next", "Waiting", "Someday" }
    end
    if not todo_data.sections[target_section] then
      todo_data.sections[target_section] = {}
    end
    table.insert(todo_data.sections[target_section], { type = "task", task = task })
    todo_data.sections[target_section] = M.sort_section_tasks(todo_data.sections[target_section])
    M.write_todo_file(todo_path, todo_data)
    vim.notify(string.format("Moved task to todo.md [%s]", target_section), vim.log.levels.INFO)
    
  elseif filename == "todo.md" then
    local current_sec = M.get_current_section()
    if current_sec == target_section then
      return
    end
    
    local todo_data = M.read_todo_file(todo_path)
    
    -- 元のセクションから削除
    if todo_data.sections[current_sec] then
      local remaining = {}
      local found = false
      for _, item in ipairs(todo_data.sections[current_sec]) do
        if not found and item.type == "task" and item.task.content == task.content and item.task.created == task.created then
          found = true
        else
          table.insert(remaining, item)
        end
      end
      todo_data.sections[current_sec] = remaining
    end
    
    -- ターゲットのセクションに追加
    if not todo_data.sections[target_section] then
      todo_data.sections[target_section] = {}
    end
    table.insert(todo_data.sections[target_section], { type = "task", task = task })
    todo_data.sections[target_section] = M.sort_section_tasks(todo_data.sections[target_section])
    
    M.write_todo_file(todo_path, todo_data)
    vim.notify(string.format("Moved task to [%s]", target_section), vim.log.levels.INFO)
  else
    vim.notify("This buffer is not inbox.md or todo.md.", vim.log.levels.WARN)
  end
end

-- タスクのキャンセル処理
function M.cancel_current_task()
  local task, row = M.get_current_task()
  if not task then
    vim.notify("Not on a task line.", vim.log.levels.WARN)
    return
  end
  
  local bufname = vim.api.nvim_buf_get_name(0)
  local filename = vim.fn.fnamemodify(bufname, ":t")
  
  local current_sec = "inbox"
  if filename == "todo.md" then
    current_sec = M.get_current_section():lower()
  elseif filename ~= "inbox.md" then
    vim.notify("This buffer is not inbox.md or todo.md.", vim.log.levels.WARN)
    return
  end
  
  local today = os.date("%Y-%m-%d")
  local current_month = os.date("%Y-%m")
  
  task.cancelled = today
  task.from = current_sec
  
  vim.api.nvim_buf_set_lines(0, row - 1, row, false, {})
  vim.cmd("silent! write")
  
  local data_dir = config.get("data_dir")
  local cancelled_path = data_dir .. "/cancelled.md"
  
  append_to_history(cancelled_path, "Cancelled", current_month, { task })
  vim.notify("Task cancelled and moved to cancelled.md", vim.log.levels.INFO)
end

return M
