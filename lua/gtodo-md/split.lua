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
    
    vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "- [ ] " })
    
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    
    local parent_text = parent_line
    
    -- マーカー部分を除去
    local t_bq, t_marker, _ = get_list_marker_info(parent_text)
    if t_marker then
      parent_text = parent_text:sub(#t_bq + #t_marker + 1)
    end
    
    -- チェックボックスを除去（[ ] や [x] など）
    parent_text = parent_text:gsub("^%s*%[.%]%s+", "")
    
    -- メタデータ (+, @, #) を除去
    parent_text = parent_text:gsub("[%+@#][%w%-_/%.%(%):]+", "")
    
    -- key:value 形式のメタデータ (例: due:2023) も除去（ただし URL の http(s) は残す）
    parent_text = parent_text:gsub("%s*[%w%-_]+:[%w%-_/%.%(%):]+", function(match)
      if match:match("^%s*https?:") then return match else return "" end
    end)
    parent_text = vim.trim(parent_text)
    
    if vim.fn.strchars(parent_text) > 40 then
      parent_text = vim.fn.strcharpart(parent_text, 0, 40) .. "..."
    end
    
    local win_opts = {
      relative = "editor", width = width, height = height,
      col = math.floor((vim.o.columns - width) / 2),
      row = math.floor((vim.o.lines - height) / 2),
      style = "minimal", border = "rounded", 
      title = " Splitting: " .. parent_text .. " ", title_pos = "center",
    }
    
    if vim.fn.has("nvim-0.10") == 1 then
      win_opts.footer = " [Commit: g<CR> or <Leader><CR>] | [Cancel: :q] "
      win_opts.footer_pos = "center"
    else
      win_opts.title = win_opts.title .. " | [Commit: g<CR>] "
    end
    
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
      if not vim.api.nvim_buf_is_valid(source_buf) or not vim.api.nvim_buf_is_loaded(source_buf) or not vim.bo[source_buf].modifiable then
        vim.notify("[gtodo-md] Source buffer is invalid, unloaded, or unmodifiable.", vim.log.levels.ERROR)
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
      local base_offset = parent_indent -- フラットモデル：親と同じインデント
      
      local injection = {}
      local expandtab = vim.bo[source_buf].expandtab
      local sw = vim.bo[source_buf].shiftwidth
      if sw == 0 then sw = vim.bo[source_buf].tabstop end
      
      local function extract_metadata(line)
        local metadata = {}
        for word in line:gmatch("[%+@#][%w%-_/%.%(%):]+") do
          table.insert(metadata, word)
        end
        for word in line:gmatch("[%w%-_]+:[%w%-_/%.%(%):]+") do
          if not word:match("^https?:") then table.insert(metadata, word) end
        end
        return metadata
      end
      
      local function get_meta_prefix(meta)
        return meta:match("^([%+@#][^%(%):]+)") or meta:match("^([^:]+:)") or meta
      end
      
      -- 親タスクからすべてのメタデータを抽出
      local parent_metadata = extract_metadata(parent_line)
      
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
          local _, l_marker, _ = get_list_marker_info(text)
          
          if l_marker then
            local existing_metadata = extract_metadata(text)
            for _, meta in ipairs(parent_metadata) do
              local meta_prefix = get_meta_prefix(meta)
              local has_meta = false
              
              for _, e_meta in ipairs(existing_metadata) do
                if get_meta_prefix(e_meta) == meta_prefix then
                  has_meta = true
                  break
                end
              end
              
              if not has_meta then
                text = text:gsub("%s*$", "") .. " " .. meta
              end
            end
          end
          
          table.insert(injection, bq_prefix .. total_indent_str .. text)
        end
      end
      
      pcall(function() vim.cmd("undojoin") end)
      -- 親タスクを削除し、分割されたタスク群に置き換える（フラットモデル）
      vim.api.nvim_buf_set_lines(source_buf, parent_row, parent_row + 1, false, injection)
      vim.api.nvim_win_close(scratch_win, true)
    end
    
    vim.keymap.set('n', 'g<CR>', commit, { buffer = scratch_buf, silent = true, desc = "Commit Split" })
    vim.keymap.set('n', '<Leader><CR>', commit, { buffer = scratch_buf, silent = true, desc = "Commit Split" })
    
    -- インサートモードでのエンターキーで自動的にチェックボックスを継続する
    vim.keymap.set('i', '<CR>', function()
      local line = vim.api.nvim_get_current_line()
      -- 現在の行が空のチェックボックスなら、それを消して通常の改行にする
      if line:match("^%s*%- %[%s*%]%s*$") then
        return "<C-u><CR>"
      -- チェックボックスがある行で改行したら、次の行にもチェックボックスを入れる
      elseif line:match("^%s*%- %[%s*%]") then
        return "<CR>- [ ] "
      else
        return "<CR>"
      end
    end, { buffer = scratch_buf, expr = true, remap = false })
    
    -- カーソルを最初の行の末尾に移動してインサートモードへ
    vim.api.nvim_win_set_cursor(scratch_win, { 1, 6 })
    vim.cmd("startinsert!")
  end)
end

return M
