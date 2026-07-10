local M = {}
local config = require('gtodo-md.config')

local active_splits = {}
local ns_id = vim.api.nvim_create_namespace("gtodo_split_ns")

local function get_list_marker_width(line)
  local bq_prefix = line:match("^(%s*>[>%s]*)") or ""
  local stripped = line:sub(#bq_prefix + 1)
  
  local u_match = stripped:match("^(%s*[%-%*+]%s+)")
  if u_match then
    return vim.fn.strdisplaywidth(u_match)
  end
  
  local o_match = stripped:match("^(%s*%d+[%.%)]%s+)")
  if o_match then
    return vim.fn.strdisplaywidth(o_match)
  end
  
  return nil
end

local function get_visual_indent(str)
  local leading = str:match("^(%s*)")
  local spaces = leading:gsub("\t", string.rep(" ", vim.bo.shiftwidth or 4))
  return #spaces
end

function M.split_current_task()
  local source_buf = vim.api.nvim_get_current_buf()
  if not vim.bo[source_buf].modifiable then
    vim.notify("[gtodo-md] Buffer is not modifiable.", vim.log.levels.WARN)
    return
  end
  
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local parent_line = vim.api.nvim_buf_get_lines(source_buf, row - 1, row, false)[1]
  if not parent_line then return end
  
  local marker_width = get_list_marker_width(parent_line)
  if not marker_width then
    vim.notify("[gtodo-md] Not on a valid task line.", vim.log.levels.WARN)
    return
  end
  
  if active_splits[source_buf] and active_splits[source_buf][row] then
    vim.notify("[gtodo-md] A split window is already active for this task.", vim.log.levels.WARN)
    return
  end
  
  local extmark_id = vim.api.nvim_buf_set_extmark(source_buf, ns_id, row - 1, 0, {})
  
  active_splits[source_buf] = active_splits[source_buf] or {}
  active_splits[source_buf][row] = true
  
  local scratch_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch_buf].bufhidden = "wipe"
  vim.bo[scratch_buf].filetype = "markdown"
  
  local virt_ns = vim.api.nvim_create_namespace("gtodo_split_virt")
  vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "" })
  vim.api.nvim_buf_set_extmark(scratch_buf, virt_ns, 0, 0, {
    virt_lines = { { { "# Splitting: " .. vim.trim(parent_line), "Comment" } } },
    virt_lines_above = true,
    right_gravity = false,
  })
  
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.6)
  local col = math.floor((vim.o.columns - width) / 2)
  local row_pos = math.floor((vim.o.lines - height) / 2)
  
  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row_pos,
    style = "minimal",
    border = "rounded",
    title = " Task Split ",
    title_pos = "center",
  }
  
  local scratch_win = vim.api.nvim_open_win(scratch_buf, true, win_opts)
  
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = scratch_buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(source_buf) then
        pcall(vim.api.nvim_buf_del_extmark, source_buf, ns_id, extmark_id)
      end
      if active_splits[source_buf] then
        active_splits[source_buf][row] = nil
      end
    end
  })
  
  local function commit()
    if not vim.api.nvim_buf_is_valid(source_buf) or not vim.bo[source_buf].modifiable then
      vim.notify("[gtodo-md] Source buffer is invalid or unmodifiable.", vim.log.levels.ERROR)
      return
    end
    
    local mark = vim.api.nvim_buf_get_extmark_by_id(source_buf, ns_id, extmark_id, {})
    if not mark or #mark == 0 then
      vim.notify("[gtodo-md] Parent task extmark was destroyed.", vim.log.levels.ERROR)
      return
    end
    
    local parent_row = mark[1]
    local current_parent_line = vim.api.nvim_buf_get_lines(source_buf, parent_row, parent_row + 1, false)[1]
    
    if current_parent_line ~= parent_line then
      local m_width = get_list_marker_width(current_parent_line)
      if not m_width then
        vim.notify("[gtodo-md] Parent task was modified and is no longer a valid task.", vim.log.levels.ERROR)
        return
      end
      
      local choice = vim.fn.confirm("Parent task text changed. Inject here?", "&Yes\n&No")
      if choice ~= 1 then return end
      
      parent_line = current_parent_line
      marker_width = m_width
    end
    
    local payload = vim.api.nvim_buf_get_lines(scratch_buf, 0, -1, false)
    if table.concat(payload, "\n"):match("^%s*$") then
      vim.notify("[gtodo-md] Empty payload. Aborting split.", vim.log.levels.INFO)
      vim.api.nvim_win_close(scratch_win, true)
      return
    end
    
    local bq_prefix = parent_line:match("^(%s*>[>%s]*)") or ""
    local stripped_parent = parent_line:sub(#bq_prefix + 1)
    local parent_indent = get_visual_indent(stripped_parent)
    local base_offset = parent_indent + marker_width
    
    local lines_in_source = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
    local inject_row = parent_row + 1
    
    while inject_row < #lines_in_source do
      local l = lines_in_source[inject_row + 1]
      if not l or l:match("^%s*$") then
        inject_row = inject_row + 1
      else
        local l_stripped = l
        if bq_prefix ~= "" and l:sub(1, #bq_prefix) == bq_prefix then
          l_stripped = l:sub(#bq_prefix + 1)
        end
        local l_indent = get_visual_indent(l_stripped)
        
        local bypass = false
        if l_stripped:match("^%s*>") and l_indent > parent_indent then
          bypass = true
        end
        
        if not bypass and l_indent <= parent_indent then
          break
        end
        
        inject_row = inject_row + 1
      end
    end
    
    while inject_row > parent_row + 1 do
      if lines_in_source[inject_row] and not lines_in_source[inject_row]:match("^%s*$") then
        break
      end
      inject_row = inject_row - 1
    end
    
    local injection = {}
    local expandtab = vim.bo[source_buf].expandtab
    local sw = vim.bo[source_buf].shiftwidth
    if sw == 0 then sw = vim.bo[source_buf].tabstop end
    
    for _, p_line in ipairs(payload) do
      if p_line:match("^%s*$") then
        table.insert(injection, bq_prefix:gsub("%s+$", ""))
      else
        local p_indent_spaces = p_line:match("^(%s*)")
        p_indent_spaces = p_indent_spaces:gsub("\t", string.rep(" ", sw))
        local total_indent_num = base_offset + #p_indent_spaces
        local total_indent_str = ""
        if not expandtab then
          local tabs = math.floor(total_indent_num / sw)
          local spaces = total_indent_num % sw
          total_indent_str = string.rep("\t", tabs) .. string.rep(" ", spaces)
        else
          total_indent_str = string.rep(" ", total_indent_num)
        end
        
        local text = p_line:match("^%s*(.*)$")
        table.insert(injection, bq_prefix .. total_indent_str .. text)
      end
    end
    
    pcall(function() vim.cmd("undojoin") end)
    vim.api.nvim_buf_set_lines(source_buf, inject_row, inject_row, false, injection)
    vim.api.nvim_win_close(scratch_win, true)
  end
  
  vim.keymap.set('n', 'g<CR>', commit, { buffer = scratch_buf, silent = true, desc = "Commit Split" })
  vim.keymap.set('n', '<Leader><CR>', commit, { buffer = scratch_buf, silent = true, desc = "Commit Split" })
  
  vim.cmd("startinsert")
end

return M
