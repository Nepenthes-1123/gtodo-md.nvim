local M = {}
local io_mod = require('gtodo-md.io')
local config = require('gtodo-md.config')

-- 様々なダッシュボード(自作スクリプト等)で汎用的に使える
-- タスクのテキストとハイライト情報のリストを返す
function M.get_tasks_lines(limit)
  limit = limit or 5
  local data_dir = config.get("data_dir")
  if not data_dir then return {} end
  
  local todo_path = data_dir .. "/todo.md"
  if vim.fn.filereadable(todo_path) == 0 then return {} end
  
  local data = io_mod.read_todo_file(todo_path)
  local today_tasks = {}
  
  if data.sections["Today"] then
    for _, item in ipairs(data.sections["Today"]) do
      if item.type == "task" and item.task.status == " " then
        table.insert(today_tasks, item.task)
        if #today_tasks >= limit then break end
      end
    end
  end
  
  local result = {}
  if #today_tasks == 0 then
    table.insert(result, { text = "  ✨ すべてのタスクが完了しています", hl = "Comment" })
  else
    for _, task in ipairs(today_tasks) do
      local content = task.content
      local icon = "  [ ] "
      
      -- 優先度によるハイライトの切り替え
      local p_match = content:match("^%(([A-Z])%)")
      local hl = "Special"
      if p_match == "A" then hl = "DiagnosticError"
      elseif p_match == "B" then hl = "DiagnosticWarn"
      elseif p_match == "C" then hl = "DiagnosticInfo" end
      
      table.insert(result, { icon = icon, text = content, hl = hl })
    end
  end
  
  return result
end

-- Snacks Dashboard (snacks.nvim) 用のウィジェットセクション
function M.snacks_section()
  return {
    pane = 2,
    header = "📅 Today's Tasks",
    icon = "📝 ",
    action = function() vim.cmd("lua require('gtodo-md').open_todo()") end,
    key = "t",
    render = function()
      local lines = M.get_tasks_lines(5)
      local render_lines = {}
      
      table.insert(render_lines, { { "📝 Today's Tasks", "Title" } })
      table.insert(render_lines, { { "", "Normal" } }) -- spacer
      
      for _, line in ipairs(lines) do
        if line.icon then
          table.insert(render_lines, { { line.icon, "Comment" }, { line.text, line.hl } })
        else
          table.insert(render_lines, { { line.text, line.hl } })
        end
      end
      
      table.insert(render_lines, { { "", "Normal" } }) -- spacer
      return render_lines
    end,
  }
end

-- Alpha (alpha-nvim) 用のウィジェットセクション
function M.alpha_section()
  local lines = M.get_tasks_lines(5)
  local alpha_lines = { "📅 Today's Tasks", "" }
  for _, line in ipairs(lines) do
    if line.icon then
      table.insert(alpha_lines, line.icon .. line.text)
    else
      table.insert(alpha_lines, line.text)
    end
  end
  
  return {
    type = "text",
    val = alpha_lines,
    opts = {
      hl = "Type",
      position = "center",
    }
  }
end

return M
