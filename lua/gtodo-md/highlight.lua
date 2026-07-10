local M = {}
local ns = vim.api.nvim_create_namespace("gtodo_highlights")
local utils = require("gtodo-md.utils")

local pending_updates = {}

local hl_groups = {
  project = "GTodoProject",         -- +Project
  context = "GTodoContext",         -- @context
  date_normal = "GTodoDate",        -- due:YYYY-MM-DD
  date_warn = "GTodoDateWarn",      -- due:today
  date_error = "GTodoDateError",    -- overdue
  priority_a = "GTodoPriorityA",    -- (A)
  priority_b = "GTodoPriorityB",    -- (B)
  priority_c = "GTodoPriorityC",    -- (C)
}

function M.setup()
  -- デフォルトのハイライトグループを定義 (ユーザーが上書き可能)
  vim.api.nvim_set_hl(0, "GTodoProject", { link = "Type", default = true })
  vim.api.nvim_set_hl(0, "GTodoContext", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "GTodoDate", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "GTodoDateWarn", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "GTodoDateError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "GTodoPriorityA", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "GTodoPriorityB", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "GTodoPriorityC", { link = "DiagnosticInfo", default = true })
end

function M.update_highlights(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  if pending_updates[bufnr] then return end
  pending_updates[bufnr] = true
  
  vim.schedule(function()
    pending_updates[bufnr] = false
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    
    local ok, err = pcall(function()
      -- 既存のハイライトをクリア
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local today_time = utils.date_to_time(os.date("%Y-%m-%d"))
  
  for i, line in ipairs(lines) do
    if utils.is_todo_line(line) or utils.is_done_line(line) then
      -- 1. Project tag (+Project)
      for s, tag in line:gmatch("()(%+[%w%-_/%.]+)") do
        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, s - 1, {
          end_col = s - 1 + #tag,
          hl_group = hl_groups.project,
          ephemeral = false,
        })
      end
      
      -- 2. Context (@context)
      for s, ctx in line:gmatch("()(@[%w%-_/%.]+)") do
        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, s - 1, {
          end_col = s - 1 + #ctx,
          hl_group = hl_groups.context,
          ephemeral = false,
        })
      end
      
      -- 3. Priority ((A), (B), (C))
      local p_s, p_c = line:match("()(%([A-Z]%))")
      if p_s then
        local p_char = p_c:sub(2, 2)
        local hl = hl_groups.priority_c
        if p_char == "A" then hl = hl_groups.priority_a
        elseif p_char == "B" then hl = hl_groups.priority_b end
        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, p_s - 1, {
          end_col = p_s - 1 + 3,
          hl_group = hl,
          ephemeral = false,
        })
      end
      
      -- 4. Due dates (due:YYYY-MM-DD)
      local d_s, d_str = line:match("()(due:%d%d%d%d%-%d%d%-%d%d)")
      if d_s then
        local date_val = d_str:sub(5)
        local due_time = utils.date_to_time(date_val)
        local hl = hl_groups.date_normal
        local vtext = ""
        
        if due_time then
          local diff = math.floor((due_time - today_time) / 86400)
          local lang = type(vim.v.lang) == "string" and vim.v.lang or os.getenv("LANG") or ""
          local time_lang = os.setlocale(nil, "time") or ""
          local is_ja = string.match(lang, "^ja")
          
          if string.match(time_lang, "^en") then
            is_ja = false
          elseif string.match(time_lang, "^ja") then
            is_ja = true
          end
          
          if diff < 0 then
            hl = hl_groups.date_error
            vtext = is_ja and string.format(" (%d日超過)", -diff) or string.format(" (%d overdue)", -diff)
          elseif diff == 0 then
            hl = hl_groups.date_warn
            vtext = is_ja and " (今日)" or " (Today)"
          elseif diff == 1 then
            hl = hl_groups.date_normal
            vtext = is_ja and " (明日)" or " (Tomorrow)"
          else
            vtext = is_ja and string.format(" (%d日後)", diff) or string.format(" (In %d days)", diff)
          end
        end
        
        -- Highlight the due date string
        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, d_s - 1, {
          end_col = d_s - 1 + #d_str,
          hl_group = hl,
          ephemeral = false,
        })
        
        -- Virtual text at end of line
        if vtext ~= "" then
          vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
            virt_text = { { vtext, hl } },
            virt_text_pos = "eol",
            hl_mode = "combine",
          })
        end
      end
    end
    end
    end)
    if not ok then
      vim.notify("GTodo highlight error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

-- 指定されたバッファに対してハイライト自動更新をセットアップする
function M.attach(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  
  -- 初回実行
  M.update_highlights(bufnr)
  
  -- 文字入力などで変更されるたびにハイライトを更新する
  local group = vim.api.nvim_create_augroup("GTodoHighlight_" .. bufnr, { clear = true })
  
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.update_highlights(bufnr)
    end
  })
end

return M
