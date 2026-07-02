local M = {}
local config = require('gtodo_md.config')
local file_mod = require('gtodo_md.file')
local ui_mod = require('gtodo_md.ui')
local timer_mod = require('gtodo_md.timer')

function M.setup(opts)
  config.setup(opts)
  
  -- ディレクトリ内のデフォルトファイルを用意する
  M.ensure_files()
  
  -- タイマー開始
  timer_mod.start_date_timer()
  timer_mod.start_waiting_timer()
  
  -- Autocmdの設定
  M.setup_autocmds()
  
  -- グローバルキーマップの設定
  if config.options.use_default_keymaps then
    M.setup_global_keymaps()
  end
end

function M.ensure_files()
  local data_dir = config.options.data_dir
  local files = {
    { path = data_dir .. "/inbox.md", title = "# Inbox" },
    { path = data_dir .. "/todo.md", title = "# Todo\n\n## Today\n\n## Next\n\n## Waiting\n\n## Someday" },
    { path = data_dir .. "/done.md", title = "# Done" },
    { path = data_dir .. "/cancelled.md", title = "# Cancelled" },
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

-- BufEnter時の自動処理
function M.handle_buf_enter(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local filename = vim.fn.fnamemodify(bufname, ":t")
  
  if filename ~= "inbox.md" and filename ~= "todo.md" then
    return
  end
  
  local data_dir = config.options.data_dir
  local inbox_path = data_dir .. "/inbox.md"
  local todo_path = data_dir .. "/todo.md"
  local done_path = data_dir .. "/done.md"
  
  -- 1. 完了タスク移動（日付変更後の初回BufEnterのみ）
  local last_opened = require('gtodo_md.utils').read_last_opened()
  local today = os.date("%Y-%m-%d")
  
  if last_opened ~= today then
    file_mod.move_completed_tasks(inbox_path, todo_path, done_path)
    require('gtodo_md.utils').write_last_opened(today)
  end
  
  -- 2. dueチェック・自動移動
  file_mod.check_dues(inbox_path, todo_path)
  
  -- 3. 自動ソート（todo.mdのみ）
  if filename == "todo.md" then
    file_mod.sort_todo_file(todo_path)
  end
  
  -- バッファローカルキーマップを登録
  if config.options.use_default_keymaps then
    M.setup_buffer_keymaps(bufnr)
  end
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("TodoNvimGroup", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = { "inbox.md", "todo.md" },
    callback = function(args)
      vim.schedule(function()
        M.handle_buf_enter(args.buf)
      end)
    end
  })
end

-- グローバルキーマップの設定
function M.setup_global_keymaps()
  -- 表示系
  vim.keymap.set('n', '<Leader>tt', function() ui_mod.open_todo_float() end, { desc = "Toggle Todo float" })
  vim.keymap.set('n', '<Leader>ti', function() ui_mod.open_inbox_float() end, { desc = "Toggle Inbox float" })
  
  -- 検索
  vim.keymap.set('n', '<Leader>t/', function() ui_mod.search_tasks() end, { desc = "Search tasks" })
  
  -- 追加・編集系 (適応的)
  vim.keymap.set('n', '<Leader>ta', function()
    local bufname = vim.api.nvim_buf_get_name(0)
    local filename = vim.fn.fnamemodify(bufname, ":t")
    
    if filename == "todo.md" or filename == "inbox.md" then
      local task, row = file_mod.get_current_task()
      if task then
        -- 編集
        require('gtodo_md.task').prompt_task(task, function(updated_task)
          local newline = require('gtodo_md.task').serialize(updated_task)
          vim.api.nvim_buf_set_lines(0, row - 1, row, false, { newline })
          vim.cmd("silent! write")
          if filename == "todo.md" then
            local todo_path = config.options.data_dir .. "/todo.md"
            file_mod.sort_todo_file(todo_path)
          end
        end)
        return
      end
    end
    
    -- 新規追加
    require('gtodo_md.task').prompt_task(nil, function(new_task)
      local newline = require('gtodo_md.task').serialize(new_task)
      local bufname = vim.api.nvim_buf_get_name(0)
      local filename = vim.fn.fnamemodify(bufname, ":t")
      
      if filename == "inbox.md" then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        table.insert(lines, newline)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.cmd("silent! write")
      elseif filename == "todo.md" then
        local current_sec = file_mod.get_current_section()
        if current_sec == "default" then current_sec = "Today" end
        local todo_path = config.options.data_dir .. "/todo.md"
        local todo_data = file_mod.read_todo_file(todo_path)
        if not todo_data.sections[current_sec] then
          todo_data.sections[current_sec] = {}
        end
        table.insert(todo_data.sections[current_sec], { type = "task", task = new_task })
        file_mod.write_todo_file(todo_path, todo_data)
        file_mod.sort_todo_file(todo_path)
      else
        local inbox_path = config.options.data_dir .. "/inbox.md"
        local inbox_data = file_mod.read_todo_file(inbox_path)
        if not inbox_data.sections["default"] then
          inbox_data.sections["default"] = {}
        end
        table.insert(inbox_data.sections["default"], { type = "task", task = new_task })
        file_mod.write_todo_file(inbox_path, inbox_data)
        vim.notify("Created new task in inbox.md", vim.log.levels.INFO)
      end
    end)
  end, { desc = "Add or edit task" })
end

-- バッファローカルなキーマップを設定する
function M.setup_buffer_keymaps(bufnr)
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
  end
  
  -- 移動系
  map('n', '<Leader>td', function() file_mod.move_current_task_to("Today") end, "Move task to Today")
  map('n', '<Leader>tn', function() file_mod.move_current_task_to("Next") end, "Move task to Next")
  map('n', '<Leader>tw', function() file_mod.move_current_task_to("Waiting") end, "Move task to Waiting")
  map('n', '<Leader>ts', function() file_mod.move_current_task_to("Someday") end, "Move task to Someday")
  
  map('n', '<Leader>tx', function() file_mod.toggle_complete() end, "Toggle task completion")
  map('n', '<Leader>tc', function() file_mod.cancel_current_task() end, "Cancel task")
  
  -- ジャンプ系
  map('n', '<Leader>tjp', function() ui_mod.jump_to_project() end, "Jump to project file")
  
  -- 機能系
  map('n', '<Leader>to', function()
    local bufname = vim.api.nvim_buf_get_name(0)
    local filename = vim.fn.fnamemodify(bufname, ":t")
    if filename == "inbox.md" then
      return
    end
    local data_dir = config.options.data_dir
    local inbox_path = data_dir .. "/inbox.md"
    local todo_path = data_dir .. "/todo.md"
    file_mod.check_dues(inbox_path, todo_path)
    file_mod.sort_todo_file(todo_path)
  end, "Sort and check due dates")
end

return M
