local M = {}
local config = require('gtodo-md.config')
local file_mod = require('gtodo-md.file')
local ui_mod = require('gtodo-md.ui')
local timer_mod = require('gtodo-md.timer')

-- 自動処理のキャッシュ用変数
local last_processed_mtimes = {
  inbox = 0,
  todo = 0,
}
local last_processed_date = ""

function M.setup(opts)
  config.setup(opts)
  
  -- ディレクトリ内のデフォルトファイルを用意する
  M.ensure_files()
  
  -- タイマー開始
  timer_mod.start_waiting_timer()
  
  -- Autocmdの設定
  M.setup_autocmds()
  
  -- グローバルキーマップの設定
  if config.get("use_default_keymaps") then
    M.setup_global_keymaps()
  end

  -- ユーザーコマンドの登録
  vim.api.nvim_create_user_command('GtodoQueue', function() ui_mod.open_queue() end, { desc = "Open Gtodo Queue view" })
end

function M.ensure_files()
  local data_dir = config.get("data_dir")
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
  
  local data_dir = config.get("data_dir")
  local inbox_path = data_dir .. "/inbox.md"
  local todo_path = data_dir .. "/todo.md"
  local done_path = data_dir .. "/done.md"
  
  local today = os.date("%Y-%m-%d")
  local current_inbox_mtime = vim.fn.getftime(inbox_path)
  local current_todo_mtime = vim.fn.getftime(todo_path)
  local is_modified = vim.bo[bufnr].modified
  
  -- スキップ判定
  local skip_process = true
  if last_processed_date ~= today then
    skip_process = false
  elseif current_inbox_mtime ~= last_processed_mtimes.inbox then
    skip_process = false
  elseif current_todo_mtime ~= last_processed_mtimes.todo then
    skip_process = false
  elseif is_modified then
    skip_process = false
  end
  
  if skip_process then
    -- 重い自動処理はスキップするが、キーマップ登録だけは毎回行う
    if config.get("use_default_keymaps") then
      M.setup_buffer_keymaps(bufnr)
    end
    return
  end
  
  -- 1. 完了タスク移動（日付変更後の初回BufEnterのみ）
  local last_opened = require('gtodo-md.utils').read_last_opened()
  
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
  if config.get("use_default_keymaps") then
    M.setup_buffer_keymaps(bufnr)
  end
  
  -- キャッシュを最新化
  last_processed_mtimes.inbox = vim.fn.getftime(inbox_path)
  last_processed_mtimes.todo = vim.fn.getftime(todo_path)
  last_processed_date = today
  
  -- 自動処理によってディスク上のファイルが変更された場合、バッファを強制同期（リロード）する
  vim.cmd("checktime")
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("TodoNvimGroup", { clear = true })
  
  -- この setup_autocmds 実行インスタンスに完全にカプセル化されたキャッシュテーブル
  -- augroup のクリア (clear = true) と連動して再初期化されるため、古い Autocmd との不整合は起きない
  local original_created_dates = {}
  local original_history_sections = {}
  
  -- todo.md 保存処理の乗っ取り (バリデーションと安全な書き込み)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = { "todo.md" },
    callback = function(args)
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      local required = { "Today", "Next", "Waiting", "Someday" }
      local found = {
        Today = false,
        Next = false,
        Waiting = false,
        Someday = false,
      }
      
      for _, line in ipairs(lines) do
        local sec = line:match("^##%s+(.*)$")
        if sec then
          sec = vim.trim(sec)
          if found[sec] ~= nil then
            found[sec] = true
          end
        end
      end
      
      local missing = {}
      for _, sec in ipairs(required) do
        if not found[sec] then
          table.insert(missing, "## " .. sec)
        end
      end
      
      if #missing > 0 then
        local msg = "[gtodo-md] 保存できません: 必須セクションが削除されています (" .. table.concat(missing, ", ") .. ")。'u' キー等で復元してください。"
        vim.api.nvim_err_writeln(msg)
        return
      end
      
      -- バリデーション成功時のみ、ディスクに書き込む (アトミック書き込み)
      local filepath = args.match
      local tmp_path = filepath .. ".tmp"
      local f = io.open(tmp_path, "w")
      if f then
        for _, line in ipairs(lines) do
          f:write(line .. "\n")
        end
        f:close()
        
        local success = (vim.fn.rename(tmp_path, filepath) == 0)
        if success then
          -- 保存成功フラグを設定 (modifiedを解除し、書き込みメッセージを出力)
          vim.bo[args.buf].modified = false
          local line_count = #lines
          local bytes = vim.fn.wordcount().bytes
          print(string.format('"%s" %dL, %dB written', vim.fn.fnamemodify(filepath, ":~"), line_count, bytes))
        else
          os.remove(tmp_path)
          vim.api.nvim_err_writeln("[gtodo-md] 保存に失敗しました (書き込みエラー)")
        end
      else
        vim.api.nvim_err_writeln("[gtodo-md] 保存に失敗しました (ファイルオープンエラー): " .. filepath)
      end
    end
  })
  
  -- done.md, cancelled.md ロード/表示時に既存の年月セクション見出しをキャッシュする
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    pattern = { "done.md", "cancelled.md" },
    callback = function(args)
      if original_history_sections[tostring(args.buf)] then return end
      
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      local original_secs = {}
      for _, line in ipairs(lines) do
        local sec = line:match("^##%s+(%d%d%d%d%-%d%d)$")
        if sec then
          original_secs[sec] = true
        end
      end
      original_history_sections[tostring(args.buf)] = original_secs
    end
  })
  
  -- inbox.md, done.md, cancelled.md 保存処理の乗っ取り (ヘッダー保護とアトミック保存)
  local history_patterns = {
    ["inbox.md"] = "# Inbox",
    ["done.md"] = "# Done",
    ["cancelled.md"] = "# Cancelled",
  }
  
  for fname, expected_header in pairs(history_patterns) do
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      pattern = fname,
      callback = function(args)
        local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
        local has_header = false
        for _, line in ipairs(lines) do
          if line:match("^" .. expected_header) then
            has_header = true
            break
          end
        end
        
        if not has_header then
          local msg = string.format("[gtodo-md] 保存できません: 必須ヘッダー (%s) が削除されています。'u' キー等で復元してください。", expected_header)
          vim.api.nvim_err_writeln(msg)
          return
        end
        
        -- 年月セクションの削除保護 (done.md と cancelled.md のみ)
        if fname == "done.md" or fname == "cancelled.md" then
          local original_secs = original_history_sections[tostring(args.buf)] or {}
          local found_secs = {}
          for _, line in ipairs(lines) do
            local sec = line:match("^##%s+(%d%d%d%d%-%d%d)$")
            if sec then
              found_secs[sec] = true
            end
          end
          
          local missing_secs = {}
          for sec, _ in pairs(original_secs) do
            if not found_secs[sec] then
              table.insert(missing_secs, "## " .. sec)
            end
          end
          
          if #missing_secs > 0 then
            local msg = string.format("[gtodo-md] 保存できません: 既存の履歴セクションが削除されています (%s)。'u' キー等で復元してください。", table.concat(missing_secs, ", "))
            vim.api.nvim_err_writeln(msg)
            return
          end
        end
        
        -- アトミック書き込みを実行
        local filepath = args.match
        local tmp_path = filepath .. ".tmp"
        local f = io.open(tmp_path, "w")
        if f then
          for _, line in ipairs(lines) do
            f:write(line .. "\n")
          end
          f:close()
          
          local success = (vim.fn.rename(tmp_path, filepath) == 0)
          if success then
            vim.bo[args.buf].modified = false
            local line_count = #lines
            local bytes = vim.fn.wordcount().bytes
            print(string.format('"%s" %dL, %dB written', vim.fn.fnamemodify(filepath, ":~"), line_count, bytes))
          else
            os.remove(tmp_path)
            vim.api.nvim_err_writeln("[gtodo-md] 保存に失敗しました (書き込みエラー)")
          end
        else
          vim.api.nvim_err_writeln("[gtodo-md] 保存に失敗しました (ファイルオープンエラー): " .. filepath)
        end
      end
    })
  end
  
  -- projects/*.md ロード/表示時に created の値とフロントマターをキャッシュする
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    pattern = { "*/projects/*.md" },
    callback = function(args)
      if original_created_dates[tostring(args.buf)] then return end
      
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      if #lines > 0 and lines[1] == "---" then
        local end_idx = nil
        for i = 2, #lines do
          if lines[i] == "---" then
            end_idx = i
            break
          end
        end
        
        if end_idx then
          for i = 2, end_idx - 1 do
            local line = lines[i]
            local created_val = line:match("^created:%s*(.*)$")
            if created_val then
              original_created_dates[tostring(args.buf)] = vim.trim(created_val)
              break
            end
          end
        end
      end
    end
  })
  
  -- projects/*.md 保存処理の乗っ取り (フロントマター保護とアトミック保存)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = { "*/projects/*.md" },
    callback = function(args)
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      local filepath = args.match
      local proj_name = vim.fn.fnamemodify(filepath, ":t:r")
      
      -- フロントマター検証
      local valid_frontmatter = false
      local created_changed = false
      local tag_matches_filename = false
      local required_keys = {
        title = false,
        tag = false,
        created = false,
        due = false,
        status = false,
        members = false,
      }
      
      if #lines > 0 and lines[1] == "---" then
        local end_idx = nil
        for i = 2, #lines do
          if lines[i] == "---" then
            end_idx = i
            break
          end
        end
        
        if end_idx then
          for i = 2, end_idx - 1 do
            local line = lines[i]
            local key, val = line:match("^(%w+):%s*(.*)$")
            if key then
              if required_keys[key] ~= nil then
                required_keys[key] = true
              end
              val = vim.trim(val or "")
              if key == "tag" and val == proj_name then
                tag_matches_filename = true
              elseif key == "created" then
                local original_created = original_created_dates[tostring(args.buf)]
                if original_created and val ~= original_created then
                  created_changed = true
                end
              end
            end
          end
          
          local missing_keys = {}
          for k, found in pairs(required_keys) do
            if not found then
              table.insert(missing_keys, k)
            end
          end
          
          if #missing_keys == 0 and tag_matches_filename and not created_changed then
            valid_frontmatter = true
          end
        end
      end
      
      if not valid_frontmatter then
        local errors = {}
        if created_changed then
          table.insert(errors, "created (作成日) の変更は禁止されています")
        end
        if not tag_matches_filename then
          table.insert(errors, string.format("tag の値がファイル名 (%s) と一致していません", proj_name))
        end
        
        local missing_keys = {}
        for k, found in pairs(required_keys) do
          if not found then
            table.insert(missing_keys, k)
          end
        end
        if #missing_keys > 0 then
          table.insert(errors, "必須項目が不足しています (" .. table.concat(missing_keys, ", ") .. ")")
        end
        
        if #errors == 0 then
          table.insert(errors, "フロントマターのフォーマット (---) が破損しています")
        end
        
        local msg = "[gtodo-md] 保存できません: " .. table.concat(errors, " / ") .. "。'u' 等で復元してください。"
        vim.api.nvim_err_writeln(msg)
        return
      end
      
      -- アトミック書き込み
      local tmp_path = filepath .. ".tmp"
      local f = io.open(tmp_path, "w")
      if f then
        for _, line in ipairs(lines) do
          f:write(line .. "\n")
        end
        f:close()
        
        local success = (vim.fn.rename(tmp_path, filepath) == 0)
        if success then
          vim.bo[args.buf].modified = false
          local line_count = #lines
          local bytes = vim.fn.wordcount().bytes
          print(string.format('"%s" %dL, %dB written', vim.fn.fnamemodify(filepath, ":~"), line_count, bytes))
        else
          os.remove(tmp_path)
          vim.api.nvim_err_writeln("[gtodo-md] 保存に失敗しました (書き込みエラー)")
        end
      else
        vim.api.nvim_err_writeln("[gtodo-md] 保存に失敗しました (ファイルオープンエラー): " .. filepath)
      end
    end
  })
  
  -- バッファが完全にメモリから消去された時のみキャッシュメモリを解放
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = { "done.md", "cancelled.md", "*/projects/*.md" },
    callback = function(args)
      local bufnr = args.buf
      -- バッファがまだ有効またはロード済みの場合は、誤検知なのでクリアをスキップする！
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        return
      end
      
      original_history_sections[tostring(bufnr)] = nil
      original_created_dates[tostring(bufnr)] = nil
    end
  })
  
  -- inbox.md, todo.md 用
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = { "inbox.md", "todo.md" },
    callback = function(args)
      vim.schedule(function()
        M.handle_buf_enter(args.buf)
      end)
    end
  })
  
  -- projects/*.md 用 (仮想テキストの描画)
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = { "*/projects/*.md" },
    callback = function(args)
      vim.schedule(function()
        require('gtodo-md.ui').render_project_tasks(args.buf)
      end)
    end
  })
  
  -- todo.md/inbox.md 保存時に、現在開いている全プロジェクトバッファの仮想テキストを更新する
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "inbox.md", "todo.md" },
    callback = function()
      vim.schedule(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) then
            require('gtodo-md.ui').render_project_tasks(buf)
          end
        end
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
          local todo_path = config.get("data_dir") .. "/todo.md"
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
      local todo_path = config.get("data_dir") .. "/todo.md"
      local todo_data = file_mod.read_todo_file(todo_path)
      if not todo_data.sections[current_sec] then
        todo_data.sections[current_sec] = {}
      end
      table.insert(todo_data.sections[current_sec], { type = "task", task = new_task })
      file_mod.write_todo_file(todo_path, todo_data)
      file_mod.sort_todo_file(todo_path)
    else
      local inbox_path = config.get("data_dir") .. "/inbox.md"
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
  local data_dir = config.get("data_dir")
  local inbox_path = data_dir .. "/inbox.md"
  local todo_path = data_dir .. "/todo.md"
  file_mod.check_dues(inbox_path, todo_path)
  file_mod.sort_todo_file(todo_path)
end

-- グローバルキーマップの設定
function M.setup_global_keymaps()
  local prefix = config.get("keymap_prefix")
  
  -- 表示系
  vim.keymap.set('n', prefix .. 't', function() ui_mod.open_todo_float() end, { desc = "Toggle Todo float" })
  vim.keymap.set('n', prefix .. 'i', function() ui_mod.open_inbox_float() end, { desc = "Toggle Inbox float" })
  
  -- 表示系 (履歴)
  vim.keymap.set('n', prefix .. 'hd', function() ui_mod.open_done_float() end, { desc = "Toggle Done float" })
  vim.keymap.set('n', prefix .. 'hc', function() ui_mod.open_cancelled_float() end, { desc = "Toggle Cancelled float" })
  
  -- 検索
  vim.keymap.set('n', prefix .. '/', function() ui_mod.search_tasks() end, { desc = "Search tasks" })
  
  -- 追加・編集系 (適応的)
  vim.keymap.set('n', prefix .. 'a', function() M.add_or_edit_task() end, { desc = "Add or edit task" })

  -- Queue ビュー
  vim.keymap.set('n', prefix .. 'q', function() ui_mod.open_queue() end, { desc = "Open Queue view" })
end

-- バッファローカルなキーマップを設定する
function M.setup_buffer_keymaps(bufnr)
  local prefix = config.get("keymap_prefix")
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
