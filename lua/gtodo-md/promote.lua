local M = {}
local config = require('gtodo-md.config')

local dos_reserved = {
  CON = true, PRN = true, AUX = true, NUL = true,
  COM1 = true, COM2 = true, COM3 = true, COM4 = true,
  COM5 = true, COM6 = true, COM7 = true, COM8 = true, COM9 = true,
  LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true,
  LPT5 = true, LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}

local function get_visual_indent(str)
  local leading = str:match("^(%s*)")
  if not leading then return 0 end
  local spaces = leading:gsub("\t", string.rep(" ", vim.bo.shiftwidth or 4))
  return #spaces
end

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

local function escape_lua_pattern(s)
  return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function escape_yaml(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  return s
end

-- Outline parsing helper: checks if a line is an un-fenced ATX header
local function is_atx_header(line, in_fence)
  if in_fence then return nil end
  local level = line:match("^%s*(#+)%s")
  if level then return #level end
  return nil
end

-- Outline parsing helper: checks if a line is a valid Setext marker
local function is_setext_marker(line, in_fence)
  if in_fence then return false end
  local indent = get_visual_indent(line)
  if indent >= 4 then return false end
  local stripped = vim.trim(line)
  if stripped:match("^===+$") then return 1 end
  if stripped:match("^---+$") then return 2 end
  return false
end

function M.promote_current_task_to_project()
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
  
  vim.ui.input({ prompt = "Enter project tag: " }, function(raw_tag)
    if not raw_tag or vim.trim(raw_tag) == "" then return end
    
    -- Sanitization
    local tag = vim.trim(raw_tag)
    tag = tag:gsub("^%.+", ""):gsub("%.+$", "") -- strip leading/trailing dots
    tag = tag:gsub('[<>:"/\\|?*]', "-")
    tag = tag:gsub("%s+", "-")
    tag = tag:gsub("%-+", "-")
    tag = tag:gsub("^%-+", ""):gsub("%-+$", "")
    if tag == "" then return end
    
    local base = tag:match("^([^.]+)")
    if base then
      local base_upper = base:upper()
      if dos_reserved[base_upper] then
        tag = tag:gsub("^([^.]+)", "%1_proj")
      end
    end
    
    local sanitized_tag = vim.fn.strcharpart(tag, 0, 80)
    
    -- Scavenging Context
    local stripped_parent = parent_line:sub(#bq_prefix + 1)
    local parent_indent = get_visual_indent(stripped_parent)
    local base_offset = parent_indent + marker_width
    
    local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
    local inject_row = row
    local in_fence = false
    
    while inject_row < #lines do
      local l = lines[inject_row + 1]
      
      -- Track fences
      local stripped_for_fence = l
      if bq_prefix ~= "" and l:sub(1, #bq_prefix) == bq_prefix then
        stripped_for_fence = l:sub(#bq_prefix + 1)
      end
      if stripped_for_fence:match("^%s*```") then
        in_fence = not in_fence
      end
      
      if l:match("^%s*$") then
        inject_row = inject_row + 1
      else
        if not in_fence then
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
        end
        inject_row = inject_row + 1
      end
    end
    
    if in_fence then
      vim.notify("[gtodo-md] Unclosed code block detected in scavenged area. Aborting.", vim.log.levels.ERROR)
      return
    end
    
    -- Backtrack
    while inject_row > row do
      if not lines[inject_row]:match("^%s*$") then
        break
      end
      inject_row = inject_row - 1
    end
    
    local scavenged_lines = {}
    for i = row + 1, inject_row do
      table.insert(scavenged_lines, lines[i])
    end
    
    local data_dir = config.get("data_dir")
    local projects_dir = data_dir .. "/projects"
    if vim.fn.isdirectory(projects_dir) == 0 then
      vim.fn.mkdir(projects_dir, "p")
    end
    
    -- Dedent Math
    local external_min_indent = math.huge
    local cb_min_indent = math.huge
    local processed_payload = {}
    
    in_fence = false
    for _, l in ipairs(scavenged_lines) do
      local p_line = l
      if bq_prefix ~= "" and l:sub(1, #bq_prefix) == bq_prefix then
        p_line = l:sub(#bq_prefix + 1)
      elseif bq_prefix ~= "" and l:match("^%s*$") then
        p_line = ""
      end
      
      -- convert tabs to spaces
      local sw = vim.bo[source_buf].shiftwidth
      if sw == 0 then sw = vim.bo[source_buf].tabstop end
      local expanded_line = p_line:gsub("\t", string.rep(" ", sw))
      
      table.insert(processed_payload, expanded_line)
      
      if not expanded_line:match("^%s*$") then
        local indent = expanded_line:match("^(%s*)")
        local indent_len = #indent
        if expanded_line:match("^%s*```") then
          in_fence = not in_fence
          if indent_len < external_min_indent then external_min_indent = indent_len end
        elseif in_fence then
          if indent_len < cb_min_indent then cb_min_indent = indent_len end
        else
          if indent_len < external_min_indent then external_min_indent = indent_len end
        end
      end
    end
    
    if external_min_indent == math.huge then external_min_indent = 0 end
    if cb_min_indent == math.huge then cb_min_indent = external_min_indent end
    local final_cb_min_indent = math.min(external_min_indent, cb_min_indent)
    
    local dedented_payload = {}
    in_fence = false
    
    local i = 1
    while i <= #processed_payload do
      local line = processed_payload[i]
      if line:match("^%s*$") then
        table.insert(dedented_payload, "")
        i = i + 1
      else
        local is_fence = line:match("^%s*```")
        if is_fence then in_fence = not in_fence end
        
        local target_dedent = in_fence and not is_fence and final_cb_min_indent or external_min_indent
        local current_spaces = line:match("^(%s*)")
        local new_spaces = math.max(0, #current_spaces - target_dedent)
        
        local text = line:sub(#current_spaces + 1)
        
        if not in_fence and not is_fence then
          -- Setext guard
          local setext_level = is_setext_marker(text, false)
          if setext_level and #dedented_payload > 0 and dedented_payload[#dedented_payload] ~= "" then
            -- Bounded upward scan to aggregate contiguous non-blank lines
            local aggregate = {}
            local walk = #dedented_payload
            while walk >= 1 and dedented_payload[walk] ~= "" do
              local t = vim.trim(dedented_payload[walk]:match("^%s*(.*)$"))
              table.insert(aggregate, 1, t)
              table.remove(dedented_payload, walk)
              walk = walk - 1
            end
            local combined = table.concat(aggregate, " ")
            local h_level = setext_level == 1 and 4 or 5
            local prefix = string.rep("#", h_level) .. " "
            table.insert(dedented_payload, prefix .. combined)
            i = i + 1 -- skip marker
            goto continue
          end
          
          -- ATX Demotion Guard
          local atx_level = is_atx_header(text, false)
          if atx_level then
            local rest = text:match("^#+%s(.*)$")
            -- We demote by 1 or 2 relative to context, but enforce floor of 4 and cap of 6
            local new_level = math.min(6, math.max(4, atx_level + 1))
            text = string.rep("#", new_level) .. " " .. rest
          end
        end
        
        local indent_str = ""
        if not vim.bo[source_buf].expandtab then
          local tabs = math.floor(new_spaces / sw)
          local spaces = new_spaces % sw
          indent_str = string.rep("\t", tabs) .. string.rep(" ", spaces)
        else
          indent_str = string.rep(" ", new_spaces)
        end
        
        table.insert(dedented_payload, indent_str .. text)
        i = i + 1
        ::continue::
      end
    end
    
    -- Buffer API Injection
    local pure_title = stripped_parent
    pure_title = pure_title:gsub("^%s*[>%s]*[%-%*+]%s+", "")
    pure_title = pure_title:gsub("^%s*[>%s]*%d+[%.%)]%s+", "")
    pure_title = pure_title:gsub("^%[%s*[xX~>%- ]?%s*%]%s*", "")
    pure_title = pure_title:match("^(.-)%s*$")
    
    local target_file = projects_dir .. "/" .. sanitized_tag .. ".md"
    
    local function perform_injection()
      local buf = vim.fn.bufadd(target_file)
      vim.fn.bufload(buf)
      local is_modified = vim.bo[buf].modified
      
      local target_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local escaped_pure_title = escape_lua_pattern(pure_title)
      
      if #target_lines > 0 then
        local found_idx = nil
        local t_in_fence = false
        for idx, t_line in ipairs(target_lines) do
          if t_line:match("^%s*```") then
            t_in_fence = not t_in_fence
          end
          if not t_in_fence and t_line:match("^###%s+" .. escaped_pure_title .. "%s*$") then
            found_idx = idx
            break
          end
        end
        
        if found_idx then
          local choice = vim.fn.confirm("Block already exists. Overwrite or Append?", "&Overwrite\n&Append\n&Cancel")
          if choice == 3 or choice == 0 then return false end
          
          local boundary_idx = found_idx + 1
          t_in_fence = false
          while boundary_idx <= #target_lines do
            local t_line = target_lines[boundary_idx]
            if t_line:match("^%s*```") then
              t_in_fence = not t_in_fence
            end
            if not t_in_fence then
              local atx = is_atx_header(t_line, false)
              if atx and atx <= 3 then break end
              local setext = is_setext_marker(t_line, false)
              if setext then
                boundary_idx = boundary_idx - 1 -- include previous text line
                break
              end
            end
            boundary_idx = boundary_idx + 1
          end
          
          local payload_to_inject = { "### " .. pure_title }
          for _, dl in ipairs(dedented_payload) do table.insert(payload_to_inject, dl) end
          table.insert(payload_to_inject, "")
          
          if choice == 1 then -- Overwrite
            vim.api.nvim_buf_set_lines(buf, found_idx - 1, boundary_idx - 1, false, payload_to_inject)
          else -- Append
            -- Find end of block exactly as boundary_idx - 1
            vim.api.nvim_buf_set_lines(buf, boundary_idx - 1, boundary_idx - 1, false, payload_to_inject)
          end
        else
          local inbox_idx = nil
          for idx, t_line in ipairs(target_lines) do
            if t_line:match("^%s*## Inbox%s*$") then
              inbox_idx = idx
              break
            end
          end
          if not inbox_idx then
            table.insert(target_lines, "")
            table.insert(target_lines, "## Inbox")
            table.insert(target_lines, "")
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, target_lines)
            inbox_idx = #target_lines - 1
          end
          
          local boundary_idx = inbox_idx + 1
          t_in_fence = false
          while boundary_idx <= #target_lines do
            local t_line = target_lines[boundary_idx]
            if t_line:match("^%s*```") then t_in_fence = not t_in_fence end
            if not t_in_fence then
              local atx = is_atx_header(t_line, false)
              if atx and atx <= 2 then break end
              local setext = is_setext_marker(t_line, false)
              if setext and setext <= 2 then
                boundary_idx = boundary_idx - 1
                break
              end
            end
            boundary_idx = boundary_idx + 1
          end
          
          local payload_to_inject = { "### " .. pure_title }
          for _, dl in ipairs(dedented_payload) do table.insert(payload_to_inject, dl) end
          table.insert(payload_to_inject, "")
          vim.api.nvim_buf_set_lines(buf, boundary_idx - 1, boundary_idx - 1, false, payload_to_inject)
        end
      else
        local iso_date = os.date("%Y-%m-%d")
        local new_lines = {
          "---",
          'title: "' .. escape_yaml(raw_tag) .. '"',
          "created: " .. iso_date,
          "---",
          "",
          "# " .. raw_tag,
          "",
          "## Inbox",
          "",
          "### " .. pure_title
        }
        for _, dl in ipairs(dedented_payload) do table.insert(new_lines, dl) end
        table.insert(new_lines, "")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
      end
      
      if not is_modified then
        vim.api.nvim_buf_call(buf, function() vim.cmd("silent! w") end)
      else
        vim.notify("[gtodo-md] " .. sanitized_tag .. ".md has unsaved changes. Target was updated but NOT saved.", vim.log.levels.INFO)
      end
      
      return true
    end
    
    local success = pcall(perform_injection)
    if success then
      pcall(function() vim.cmd("undojoin") end)
      
      -- Parent Mutation
      local escaped_tag = escape_lua_pattern(sanitized_tag)
      local new_parent_line = parent_line
      if not parent_line:match("(%s|^)%+%s*" .. escaped_tag .. "%s*$") then
        new_parent_line = parent_line:gsub("%s*$", "") .. " +" .. sanitized_tag
      end
      
      local u_cb = "^(%s*[>%s]*[%-%*+]%s+)%[[xX~>%- ]?%]"
      local o_cb = "^(%s*[>%s]*%d+[%.%)]%s+)%[[xX~>%- ]?%]"
      if new_parent_line:match(u_cb) then
        new_parent_line = new_parent_line:gsub(u_cb, "%1[>]")
      elseif new_parent_line:match(o_cb) then
        new_parent_line = new_parent_line:gsub(o_cb, "%1[>]")
      else
        local u_nocb = "^(%s*[>%s]*[%-%*+]%s+)"
        local o_nocb = "^(%s*[>%s]*%d+[%.%)]%s+)"
        if new_parent_line:match(u_nocb) then
          new_parent_line = new_parent_line:gsub(u_nocb, "%1[>] ")
        elseif new_parent_line:match(o_nocb) then
          new_parent_line = new_parent_line:gsub(o_nocb, "%1[>] ")
        end
      end
      
      vim.api.nvim_buf_set_lines(source_buf, row - 1, inject_row, false, { new_parent_line })
      
      vim.cmd("e " .. vim.fn.fnameescape(target_file))
    end
  end)
end

return M
