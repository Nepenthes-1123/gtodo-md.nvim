local M = {}
local config = require('gtodo-md.config')
local file_mod = require('gtodo-md.file')
local ui_mod = require('gtodo-md.ui')
local timer_mod = require('gtodo-md.timer')

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
  local last_opened = require('gtodo-md.utils').read_last_opened()
  local today = os.date("%Y-%m-%d")
  
  if last_opened ~= today then
    file_mod.move_completed_tasks(inbox_path, todo_path, done_path)
    require('gtodo-md.utils').write_last_opened(today)
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

-- 適応的なタスクの追加または編集 (外部呼び出し可能)
function M.add_or_edit_task()
  local bufname = vim.api.nvim_buf_get_name(0)
  local filename = vim.fn.fnamemodify(bufname, ":t")
  
  if filename == "todo.md" or filename == "inbox.md" then
    local task, row = file_mod.get_current_task()
    if task then
      -- 編集
      require('gtodo-md.task').prompt_task(task, function(updated_task)
        local newline = require('gtodo-md.task').serialize(updated_task)
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
  require('gtodo-md.task').prompt_task(nil, function(new_task)
    local newline = require('gtodo-md.task').serialize(new_task)
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
end

-- 手動ソートと期日チェック (外部呼び出し可能)
function M.sort_and_check_dues()
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
end

-- グローバルキーマップの設定
function M.setup_global_keymaps()
  local prefix = config.options.keymap_prefix or "<Leader>t"
  
  -- 表示系
  vim.keymap.set('n', prefix .. 't', function() ui_mod.open_todo_float() end, { desc = "Toggle Todo float" })
  vim.keymap.set('n', prefix .. 'i', function() ui_mod.open_inbox_float() end, { desc = "Toggle Inbox float" })
  
  -- 検索
  vim.keymap.set('n', prefix .. '/', function() ui_mod.search_tasks() end, { desc = "Search tasks" })
  
  -- 追加・編集系 (適応的)
  vim.keymap.set('n', prefix .. 'a', function() M.add_or_edit_task() end, { desc = "Add or edit task" })
end

-- バッファローカルなキーマップを設定する
function M.setup_buffer_keymaps(bufnr)
  local prefix = config.options.keymap_prefix or "<Leader>t"
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
  end
  
  -- 移動系
  map('n', prefix .. 'd', function() file_mod.move_current_task_to("Today") end, "Move task to Today")
  map('n', prefix .. 'n', function() file_mod.move_current_task_to("Next") end, "Move task to Next")
  map('n', prefix .. 'w', function() file_mod.move_current_task_to("Waiting") end, "Move task to Waiting")
  map('n', prefix .. 's', function() file_mod.move_current_task_to("Someday") end, "Move task to Someday")
  
  map('n', prefix .. 'x', function() file_mod.toggle_complete() end, "Toggle task completion")
  map('n', prefix .. 'c', function() file_mod.cancel_current_task() end, "Cancel task")
  
  -- ジャンプ系
  map('n', prefix .. 'jp', function() ui_mod.jump_to_project() end, "Jump to project file")
  
  -- 機能系
  map('n', prefix .. 'o', function() M.sort_and_check_dues() end, "Sort and check due dates")
end

return M
