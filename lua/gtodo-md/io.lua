local M = {}
local task_mod = require('gtodo-md.task')
local config = require('gtodo-md.config')

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

function M.format_buffer(bufnr)
  pcall(function()
    if package.loaded["conform"] then
      require("conform").format({ bufnr = bufnr, async = false })
    elseif vim.fn.exists(":Neoformat") == 2 then
      vim.cmd("Neoformat")
    elseif vim.fn.exists(":Format") == 2 then
      vim.cmd("Format")
    else
      vim.lsp.buf.format({ bufnr = bufnr, async = false })
    end
  end)
end

-- 差分のみを更新し、Extmarksの破壊を防ぐ
local function update_lines_incrementally(buf, new_lines)
  local old_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_idx = 1
  while start_idx <= #old_lines and start_idx <= #new_lines and old_lines[start_idx] == new_lines[start_idx] do
    start_idx = start_idx + 1
  end
  
  local end_old = #old_lines
  local end_new = #new_lines
  while end_old >= start_idx and end_new >= start_idx and old_lines[end_old] == new_lines[end_new] do
    end_old = end_old - 1
    end_new = end_new - 1
  end
  
  if start_idx > #old_lines and start_idx > #new_lines then
    return -- 変更なし
  end
  
  local replacement = {}
  for i = start_idx, end_new do
    table.insert(replacement, new_lines[i])
  end
  
  vim.api.nvim_buf_set_lines(buf, start_idx - 1, end_old, false, replacement)
end

-- ファイルまたはバッファに行リストを書き込む
function M.write_lines(path, lines)
  local buf = get_buf_by_name(path)
  
  if buf then
    update_lines_incrementally(buf, lines)
    M.format_buffer(buf)
    -- 未保存の編集内容を上書きしないよう、保存はユーザーのアクションやBufWritePreに委ねる
  else
    local tmp_path = path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if f then
      for _, line in ipairs(lines) do
        f:write(line .. "\n")
      end
      f:close()
      vim.fn.rename(tmp_path, path)
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
          -- 空行はソート時のインデックスズレやMarkdownリスト分断の原因になるため無視する
          if vim.trim(line) ~= "" then
            table.insert(data.sections[current_section], { type = "text", line = line })
          end
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
  
  if data.sections["default"] and #data.sections["default"] > 0 then
    if #lines > 0 and lines[#lines] ~= "" then
      table.insert(lines, "")
    end
    for _, item in ipairs(data.sections["default"]) do
      if item.type == "task" then
        table.insert(lines, task_mod.serialize(item.task))
      else
        local text = item.line
        if vim.trim(text) == "" then
          if #lines > 0 and vim.trim(lines[#lines]) ~= "" then
            table.insert(lines, text)
          end
        else
          table.insert(lines, text)
        end
      end
    end
  end
  
  for _, sec in ipairs(data.section_order) do
    if #lines > 0 and lines[#lines] ~= "" then
      table.insert(lines, "")
    end
    table.insert(lines, "## " .. sec)
    table.insert(lines, "")
    
    local items = data.sections[sec] or {}
    for _, item in ipairs(items) do
      if item.type == "task" then
        table.insert(lines, task_mod.serialize(item.task))
      else
        local text = item.line
        if vim.trim(text) == "" then
          if #lines > 0 and vim.trim(lines[#lines]) ~= "" then
            table.insert(lines, text)
          end
        else
          table.insert(lines, text)
        end
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

function M.ensure_files()
  local data_dir = config.get("data_dir")
  local files = {
    { path = data_dir .. "/inbox.md", title = "# Inbox\n" },
    { path = data_dir .. "/todo.md", title = string.format("# Todo\n\n## %s\n\n## %s\n\n## %s\n\n## %s", config.sections.TODAY, config.sections.NEXT, config.sections.WAITING, config.sections.SOMEDAY) },
    { path = data_dir .. "/done.md", title = "# Done\n" },
    { path = data_dir .. "/cancelled.md", title = "# Cancelled\n" },
  }
  
  for _, f in ipairs(files) do
    if vim.fn.filereadable(f.path) == 0 then
      local file = io.open(f.path, "w")
      if file then
        file:write(f.title .. "\n")
        file:close()
      end
    end
  end
end

return M
