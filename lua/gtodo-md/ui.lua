local M = {}
local config = require('gtodo-md.config')

-- フローティングウィンドウでファイルを開く
function M.open_float(filepath, title)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)
  
  local buf = vim.api.nvim_create_buf(false, true)
  
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  }
  
  local win = vim.api.nvim_open_win(buf, true, opts)
  
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  
  local file_buf = vim.api.nvim_get_current_buf()
  vim.bo[file_buf].buflisted = false
  vim.bo[file_buf].bufhidden = "wipe"
  
  vim.api.nvim_buf_set_keymap(file_buf, 'n', 'q', ':q<CR>', { noremap = true, silent = true })
  
  return file_buf, win
end

function M.open_todo_float()
  local path = config.options.data_dir .. "/todo.md"
  M.open_float(path, "Todo")
end

function M.open_inbox_float()
  local path = config.options.data_dir .. "/inbox.md"
  M.open_float(path, "Inbox")
end

function M.open_done_float()
  local path = config.options.data_dir .. "/done.md"
  M.open_float(path, "Done")
end

function M.open_cancelled_float()
  local path = config.options.data_dir .. "/cancelled.md"
  M.open_float(path, "Cancelled")
end

-- AND絞り込み検索
function M.search_tasks()
  local data_dir = config.options.data_dir
  local files = {
    data_dir .. "/inbox.md",
    data_dir .. "/todo.md",
    data_dir .. "/done.md"
  }
  
  local task_mod = require('gtodo-md.task')
  local items = {}
  
  for _, filepath in ipairs(files) do
    if vim.fn.filereadable(filepath) == 1 then
      local lines = {}
      local f = io.open(filepath, "r")
      if f then
        for line in f:lines() do
          table.insert(lines, line)
        end
        f:close()
      end
      
      for lnum, line in ipairs(lines) do
        local task = task_mod.parse(line)
        if task then
          local fname = vim.fn.fnamemodify(filepath, ":t:r")
          local display_text = string.format("[%s] %s", fname:upper(), line)
          table.insert(items, {
            text = display_text,
            file = filepath,
            pos = { lnum, 1 },
          })
        end
      end
    end
  end
  
  local picker_opt = config.options.picker or "auto"

  local function try_snacks()
    local has_snacks, snacks = pcall(require, "snacks")
    if has_snacks and snacks.picker then
      snacks.picker.pick({
        title = "Gtodo Search",
        items = items,
        format = "text",
      })
      return true
    end
    return false
  end

  local function try_telescope()
    local has_telescope, telescope = pcall(require, "telescope")
    if has_telescope then
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      pickers.new({}, {
        prompt_title = "Gtodo Search",
        finder = finders.new_table({
          results = items,
          entry_maker = function(entry)
            return {
              value = entry,
              display = entry.text,
              ordinal = entry.text,
              filename = entry.file,
              lnum = entry.pos[1],
              col = entry.pos[2],
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        previewer = conf.qflist_previewer({}),
      }):find()
      return true
    end
    return false
  end

  local function try_fzf()
    local has_fzf, fzf = pcall(require, "fzf-lua")
    if has_fzf then
      local fzf_items = {}
      for _, item in ipairs(items) do
        table.insert(fzf_items, string.format("%s:%d:%d:%s", item.file, item.pos[1], item.pos[2], item.text))
      end
      fzf.fzf_exec(fzf_items, {
        prompt = "Gtodo Search> ",
        actions = fzf.defaults.actions.file_edit,
        previewer = "builtin",
      })
      return true
    end
    return false
  end

  -- ピッカー実行分岐
  local launched = false
  if picker_opt == "snacks" then
    launched = try_snacks()
  elseif picker_opt == "telescope" then
    launched = try_telescope()
  elseif picker_opt == "fzf-lua" then
    launched = try_fzf()
  elseif picker_opt == "auto" then
    launched = try_snacks() or try_telescope() or try_fzf()
  end

  if launched then
    return
  end
  
  -- Snacks がない場合は従来の vim.ui.input + quickfix 検索
  vim.ui.input({
    prompt = "Search filter (e.g. +project @15 [ ]): ",
    default = ""
  }, function(query)
    if not query then return end
    query = vim.trim(query)
    
    local target_project = query:match("%+([%w%-]+)")
    local target_context = query:match("(@%w+)")
    local target_status = nil
    if query:match("%[%s*%]") then
      target_status = " "
    elseif query:match("%[x%]") then
      target_status = "x"
    end
    
    local qf_list = {}
    for _, item in ipairs(items) do
      local line = item.text:match("^%[[%w%-]+%]%s*(.*)$")
      local task = task_mod.parse(line)
      if task then
        local match = true
        if target_project and task.project ~= target_project then
          match = false
        end
        if target_context then
          local tc = target_context
          local tc_clean = tc:match("^@") and tc or ("@" .. tc)
          local task_ctx = task.context
          local task_ctx_clean = task_ctx and (task_ctx:match("^@") and task_ctx or ("@" .. task_ctx))
          if task_ctx_clean ~= tc_clean then
            match = false
          end
        end
        if target_status and task.status ~= target_status then
          match = false
        end
        
        if match then
          table.insert(qf_list, {
            filename = item.file,
            lnum = item.pos[1],
            text = line,
          })
        end
      end
    end
    
    if #qf_list == 0 then
      vim.notify("No matching tasks found.", vim.log.levels.INFO)
      return
    end
    
    vim.fn.setqflist(qf_list, "r")
    vim.fn.setqflist({}, "r", { title = string.format("Gtodo Search: %s", query) })
    vim.cmd("copen")
  end)
end

-- プロジェクトファイルへのジャンプ
function M.jump_to_project()
  local current_line = vim.api.nvim_get_current_line()
  local project_tag = current_line:match("%+([%w%-]+)")
  
  if not project_tag then
    return
  end
  
  local data_dir = config.options.data_dir
  local proj_file = string.format("%s/projects/%s.md", data_dir, project_tag)
  
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
    
    local f = io.open(proj_file, "w")
    if f then
      for _, l in ipairs(template) do
        f:write(l .. "\n")
      end
      f:close()
    else
      vim.notify("Failed to create project file: " .. proj_file, vim.log.levels.ERROR)
      return
    end
  end
  
  M.open_float(proj_file, "Project: " .. project_tag)
end

function M.render_project_tasks(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local filedir = vim.fn.fnamemodify(bufname, ":h:t")
  local filename = vim.fn.fnamemodify(bufname, ":t:r")
  
  -- projects ディレクトリ配下の markdown ファイルのみ対象
  if filedir ~= "projects" or vim.fn.fnamemodify(bufname, ":e") ~= "md" then
    return
  end
  
  local data_dir = config.options.data_dir
  local inbox_path = data_dir .. "/inbox.md"
  local todo_path = data_dir .. "/todo.md"
  
  local file_mod = require('gtodo-md.file')
  local project_tag = filename
  
  local active_tasks = {}
  
  -- inbox.md から該当プロジェクトの未完了タスクを取得
  if vim.fn.filereadable(inbox_path) == 1 then
    local inbox_data = file_mod.read_todo_file(inbox_path)
    if inbox_data.sections["default"] then
      for _, item in ipairs(inbox_data.sections["default"]) do
        if item.type == "task" and item.task.status ~= "x" and item.task.project == project_tag then
          table.insert(active_tasks, item.task)
        end
      end
    end
  end
  
  -- todo.md から該当プロジェクトの未完了タスクを取得
  if vim.fn.filereadable(todo_path) == 1 then
    local todo_data = file_mod.read_todo_file(todo_path)
    for _, sec in ipairs(todo_data.section_order) do
      if todo_data.sections[sec] then
        for _, item in ipairs(todo_data.sections[sec]) do
          if item.type == "task" and item.task.status ~= "x" and item.task.project == project_tag then
            table.insert(active_tasks, item.task)
          end
        end
      end
    end
  end
  
  -- 仮想テキストの描画処理
  local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  
  if #active_tasks == 0 then
    return
  end
  
  -- 仮想行の組み立て (標準的な Markdown テキスト表現と Comment グループによるポータブルな表示)
  local virt_lines = {
    { { "", "" } },
    { { "----------------------------------------", "Comment" } },
    { { "[gtodo-md] 進行中のタスク (+" .. project_tag .. "):", "Comment" } },
  }
  
  for _, task in ipairs(active_tasks) do
    local line_parts = {}
    table.insert(line_parts, { "  - [ ] ", "Comment" })
    table.insert(line_parts, { task.content, "Comment" })
    
    if task.context then
      table.insert(line_parts, { " @" .. task.context, "Comment" })
    end
    
    if task.due then
      table.insert(line_parts, { " due:" .. task.due, "Comment" })
    end
    
    table.insert(virt_lines, line_parts)
  end
  
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_count - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })
end

return M
