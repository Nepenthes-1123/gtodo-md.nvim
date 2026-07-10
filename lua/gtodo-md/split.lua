local M = {}
local config = require('gtodo-md.config')

local active_splits = {}
local ns_id = vim.api.nvim_create_namespace("gtodo_split_ns")

local function get_list_marker_info(line)
  local bq_prefix = line:match("^(%s*>[>%s]*)") or ""
  local stripped = line:sub(#bq_prefix + 1)
  
  local u_match = stripped:match("^(%s*[%-%*+]%s+)")
  if u_match then
    return bq_prefix, u_match, vim.fn.strdisplaywidth(u_match)
  end
  
  local o_match = stripped:match("^(%s*%d+[%.%)]%s+)")
  if o_match then
    return bq_prefix, o_match, vim.fn.strdisplaywidth(o_match)
  end
  
  return bq_prefix, nil, nil
end

local function get_visual_indent(str)
  local leading = str:match("^(%s*)")
  if not leading then return 0 end
  local spaces = leading:gsub("\t", string.rep(" ", vim.bo.shiftwidth or 4))
  return #spaces
end

local function escape_lua_pattern(s)
  return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function create_project_file_if_missing(tag)
  local data_dir = config.get("data_dir")
  local proj_file = string.format("%s/projects/%s.md", data_dir, tag)
  if vim.fn.filereadable(proj_file) == 0 then
    local projects_dir = data_dir .. "/projects"
    if vim.fn.isdirectory(projects_dir) == 0 then
      vim.fn.mkdir(projects_dir, "p")
    end
    local today = os.date("%Y-%m-%d")
    local template = {
      "---",
      'title: "' .. tag .. '"',
      "tag: " .. tag,
      "created: " .. today,
      "due: ",
      "status: active",
      "members: []",
      "---",
      "",
      "## Overview",
      "",
      "## Inbox",
      ""
    }
    local f = io.open(proj_file, "w")
    if f then
      for _, l in ipairs(template) do f:write(l .. "\n") end
      f:close()
    end
  end
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
  
  local bq_prefix, marker, marker_width = get_list_marker_info(parent_line)
  if not marker then
    vim.notify("[gtodo-md] Not on a valid task line.", vim.log.levels.WARN)
    return
  end
  
  if active_splits[source_buf] and active_splits[source_buf][row] then
    vim.notify("[gtodo-md] A split window is already active for this task.", vim.log.levels.WARN)
    return
  end
  
  local existing_tag = parent_line:match("%+([%w%-_/%.]+)")
  
  vim.ui.input({ prompt = "Project tag (empty for plain split): ", default = existing_tag or "" }, function(input_tag)
    if input_tag == nil then return end 
    
    local new_tag = vim.trim(input_tag)
    
    if new_tag ~= "" then
      new_tag = new_tag:gsub("^%.+", ""):gsub("%.+$", "")
      new_tag = new_tag:gsub('[<>:"/\\|?*]', "-")
      new_tag = new_tag:gsub("%s+", "-")
      new_tag = new_tag:gsub("%-+", "-")
      new_tag = new_tag:gsub("^%-+", ""):gsub("%-+$", "")
      
      if new_tag == "" then return end
      
      local base = new_tag:match("^([^.]+)")
      if base then
        local dos_reserved = { CON=true, PRN=true, AUX=true, NUL=true, COM1=true, COM2=true, COM3=true, COM4=true, LPT1=true, LPT2=true, LPT3=true }
        if dos_reserved[base:upper()] then
          new_tag = new_tag:gsub("^([^.]+)", "%1_proj")
        end
      end
      new_tag = vim.fn.strcharpart(new_tag, 0, 80)
      
      create_project_file_if_missing(new_tag)
    end
    
    local new_parent_line = parent_line
    if existing_tag and new_tag == "" then
      new_parent_line = new_parent_line:gsub("%s*%+" .. escape_lua_pattern(existing_tag) .. "%s*$", "")
    elseif existing_tag and new_tag ~= "" and existing_tag ~= new_tag then
      new_parent_line = new_parent_line:gsub("%+" .. escape_lua_pattern(existing_tag) .. "(%s*)$", "+" .. new_tag .. "%1")
    elseif not existing_tag and new_tag ~= "" then
      new_parent_line = new_parent_line:gsub("%s*$", "") .. " +" .. new_tag
    end
    
    if new_parent_line ~= parent_line then
      vim.api.nvim_buf_set_lines(source_buf, row - 1, row, false, { new_parent_line })
    end
    
    parent_line = vim.api.nvim_buf_get_lines(source_buf, row - 1, row, false)[1]
    
    local extmark_id = vim.api.nvim_buf_set_extmark(source_buf, ns_id, row - 1, 0, {
      right_gravity = false,
    })
    
    active_splits[source_buf] = active_splits[source_buf] or {}
    active_splits[source_buf][row] = true
    
    local scratch_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch_buf].bufhidden = "wipe"
    vim.bo[scratch_buf].filetype = "markdown"
    
    vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "" })
    
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    
    local win_opts = {
      relative = "editor", width = width, height = height,
      col = math.floor((vim.o.columns - width) / 2),
      row = math.floor((vim.o.lines - height) / 2),
      style = "minimal", border = "rounded", title = " Task Split ", title_pos = "center",
    }
    
    if vim.fn.has("nvim-0.10") == 1 then
      win_opts.footer = " [Commit: g<CR> or <Leader><CR>] | [Cancel: :q] "
      win_opts.footer_pos = "center"
    else
      win_opts.title = " [Commit: g<CR> or <Leader><CR>] | [Cancel: :q] "
    end
    
    local scratch_win = vim.api.nvim_open_win(scratch_buf, true, win_opts)
    
    -- Winbar を使って、スクロールしても絶対に画面外へ行かないヘッダーを実装
    local parent_text = vim.trim(parent_line)
    -- winbar全体を親タスク名に割り当てる
    vim.wo[scratch_win].winbar = "%#Title# # Splitting: " .. parent_text

    
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
        local c_bq_prefix, c_marker, c_marker_width = get_list_marker_info(current_parent_line)
        if not c_marker then
          vim.notify("[gtodo-md] Parent task was modified and is no longer a valid task.", vim.log.levels.ERROR)
          return
        end
        
        local choice = vim.fn.confirm("Parent task text changed. Inject here?", "&Yes\n&No")
        if choice ~= 1 then return end
        
        parent_line = current_parent_line
        bq_prefix = c_bq_prefix
        marker_width = c_marker_width
      end
      
      local payload = vim.api.nvim_buf_get_lines(scratch_buf, 0, -1, false)
      if table.concat(payload, "\n"):match("^%s*$") then
        vim.notify("[gtodo-md] Empty payload. Aborting split.", vim.log.levels.INFO)
        vim.api.nvim_win_close(scratch_win, true)
        return
      end
      
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
          
          if new_tag ~= "" then
            local _, l_marker, _ = get_list_marker_info(text)
            if l_marker and not text:match("%+" .. escape_lua_pattern(new_tag) .. "%s*$") then
               text = text:gsub("%s*$", "") .. " +" .. new_tag
            end
          end
          
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
  end)
end

return M
