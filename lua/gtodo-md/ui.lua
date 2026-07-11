local M = {}
local config = require('gtodo-md.config')
local utils  = require('gtodo-md.utils')

-- 現在開いているgtodoフローティングウィンドウ (1つだけ管理)
local gtodo_float_win = nil

local function close_current_float()
  if gtodo_float_win and vim.api.nvim_win_is_valid(gtodo_float_win) then
    vim.api.nvim_win_close(gtodo_float_win, true)
  end
  gtodo_float_win = nil
end

local function register_float_win(win)
  gtodo_float_win = win
end

-- done.md のカウントキャッシュ
local done_cache = {
  mtime = 0,
  counts = {}
}

-- done.md から高速にプロジェクトごとの完了件数を取得するヘルパー
local function get_done_project_counts(done_path)
  if vim.fn.filereadable(done_path) == 0 then
    return {}
  end
  local current_mtime = vim.fn.getftime(done_path)
  if current_mtime == done_cache.mtime then
    return done_cache.counts
  end
  
  local counts = {}
  local f = io.open(done_path, "r")
  if f then
    local content = f:read("*all")
    f:close()
    
    -- 高速テキスト走査で完了タスクとプロジェクトタグをカウント
    for line in content:gmatch("[^\r\n]+") do
      if require('gtodo-md.utils').is_done_line(line) then
        local tag = line:match("%+([%w%-_/%.]+)")
        if tag then
          counts[tag] = (counts[tag] or 0) + 1
        end
      end
    end
  end
  
  done_cache.mtime = current_mtime
  done_cache.counts = counts
  return counts
end

-- フローティングウィンドウでファイルを開く
function M.open_float(filepath, title)
  -- 既存のgtodoフロートを閉じてから新しく開く
  close_current_float()

  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

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
  register_float_win(win)

  vim.cmd("edit " .. vim.fn.fnameescape(filepath))

  local file_buf = vim.api.nvim_get_current_buf()
  vim.bo[file_buf].buflisted = false
  vim.bo[file_buf].bufhidden = "wipe"

  vim.api.nvim_buf_set_keymap(file_buf, 'n', 'q',     ':q<CR>', { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(file_buf, 'n', '<Esc>', ':q<CR>', { noremap = true, silent = true })

  return file_buf, win
end

function M.open_todo_float()
  local path = config.get("data_dir") .. "/todo.md"
  M.open_float(path, "Todo")
end

function M.open_inbox_float()
  local path = config.get("data_dir") .. "/inbox.md"
  M.open_float(path, "Inbox")
end

function M.open_done_float()
  local path = config.get("data_dir") .. "/done.md"
  M.open_float(path, "Done")
end

function M.open_cancelled_float()
  local path = config.get("data_dir") .. "/cancelled.md"
  M.open_float(path, "Cancelled")
end

-- AND絞り込み検索
function M.search_tasks()
  local data_dir = config.get("data_dir")
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
          local _, _, clean_line = line:match("^(%s*)%-%s*%[([ xX])%]%s*(.*)$")
          clean_line = clean_line or line
          local display_text = string.format("[%s] %s", fname:upper(), clean_line)
          table.insert(items, {
            text = display_text,
            original_line = line,
            file = filepath,
            pos = { lnum, 1 },
          })
        end
      end
    end
  end
  
  local picker_opt = config.get("picker")
  
  local pickers = {
    snacks = function(items)
      local ok, p = pcall(require, "gtodo-md.integrations.picker")
      return ok and p.snacks(items)
    end,
    telescope = function(items)
      local ok, p = pcall(require, "gtodo-md.integrations.picker")
      return ok and p.telescope(items)
    end,
    ["fzf-lua"] = function(items)
      local ok, p = pcall(require, "gtodo-md.integrations.picker")
      return ok and p.fzf_lua(items)
    end
  }

  local launched = false
  if picker_opt == "auto" then
    launched = pickers.snacks(items) or pickers.telescope(items) or pickers["fzf-lua"](items)
  elseif pickers[picker_opt] then
    launched = pickers[picker_opt](items)
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
    query = query:gsub("　", " ")
    
    local target_project = query:match("%+([%w%-_/%.]+)")
    local target_context = query:match("(@[%w%-_/%.]+)")
    local target_status = nil
    if query:match("%[%s*%]") then
      target_status = " "
    elseif query:match("%[x%]") then
      target_status = "x"
    end
    
    local qf_list = {}
    for _, item in ipairs(items) do
      local task = task_mod.parse(item.original_line)
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
            text = item.text,
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
  local project_tag = current_line:match("%+([%w%-_/%.]+)")
  
  if not project_tag then
    return
  end
  
  local data_dir = config.get("data_dir")
  local proj_file = string.format("%s/projects/%s.md", data_dir, project_tag)
  
  if vim.fn.filereadable(proj_file) == 0 then
    local ok = require('gtodo-md.utils').create_project_file(project_tag)
    if not ok then return end
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
  
  local data_dir = config.get("data_dir")
  local inbox_path = data_dir .. "/inbox.md"
  local todo_path = data_dir .. "/todo.md"
  
  local io_mod = require('gtodo-md.io')
  local project_tag = filename
  
  local active_tasks = {}
  local completed_count = 0
  
  -- done.md から過去の完了件数を取得 (高速キャッシュ経由)
  local done_path = data_dir .. "/done.md"
  local done_counts = get_done_project_counts(done_path)
  completed_count = completed_count + (done_counts[project_tag] or 0)
  
  -- inbox.md から該当プロジェクトのタスクを取得
  if vim.fn.filereadable(inbox_path) == 1 then
    local inbox_data = io_mod.read_todo_file(inbox_path)
    if inbox_data.sections["default"] then
      for _, item in ipairs(inbox_data.sections["default"]) do
        if item.type == "task" and item.task.project == project_tag then
          if item.task.status == "x" then
            completed_count = completed_count + 1
          else
            table.insert(active_tasks, item.task)
          end
        end
      end
    end
  end
  
  -- todo.md から該当プロジェクトのタスクを取得
  if vim.fn.filereadable(todo_path) == 1 then
    local todo_data = io_mod.read_todo_file(todo_path)
    for _, sec in ipairs(todo_data.section_order) do
      if todo_data.sections[sec] then
        for _, item in ipairs(todo_data.sections[sec]) do
          if item.type == "task" and item.task.project == project_tag then
            if item.task.status == "x" then
              completed_count = completed_count + 1
            else
              table.insert(active_tasks, item.task)
            end
          end
        end
      end
    end
  end
  
  -- 仮想テキストの描画処理
  local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  
  local total_count = #active_tasks + completed_count
  if total_count == 0 then
    return
  end
  
  -- 仮想行の組み立て
  local virt_lines = {
    { { "", "" } },
    { { "----------------------------------------", "Comment" } },
  }
  
  local show_progress = config.get("enable_project_progress")
  if show_progress == nil then show_progress = true end
  
  if show_progress then
    -- 進捗率と進捗バーの計算
    local progress_percent = 0
    if total_count > 0 then
      progress_percent = math.floor((completed_count / total_count) * 100)
    end
    
    local bar_width = 10
    local filled = math.floor((progress_percent / 100) * bar_width)
    local empty = bar_width - filled
    local bar_str = string.format("[%s%s] %d%% (%d/%d done)", 
                                  string.rep("█", filled), 
                                  string.rep("░", empty), 
                                  progress_percent, 
                                  completed_count, 
                                  total_count)
    table.insert(virt_lines, { { "[gtodo-md] プロジェクト進捗: " .. bar_str, "DiagnosticOk" } })
  end
  
  if #active_tasks > 0 then
    table.insert(virt_lines, { { "[gtodo-md] 進行中のタスク (+" .. project_tag .. "):", "Comment" } })
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
  else
    table.insert(virt_lines, { { "[gtodo-md] すべてのタスクが完了しました！", "DiagnosticOk" } })
  end
  
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_count - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })
end

-- Queue ビュー: due または wait 付き未完了タスクを表示する
-- mode: "due" (デフォルト) または "wait"
function M.open_queue(mode, previous_target_id)
  mode = mode or "due"
  local data_dir = config.get("data_dir")
  local io_mod = require('gtodo-md.io')

  -- inbox.md と todo.md から対象タスクを収集
  local source_files = {
    data_dir .. "/inbox.md",
    data_dir .. "/todo.md",
  }

  local tasks = {}

  for _, filepath in ipairs(source_files) do
    if vim.fn.filereadable(filepath) == 1 then
      local lines = io_mod.read_lines(filepath)
      local task_mod = require('gtodo-md.task')
      for lnum, line in ipairs(lines) do
        local task = task_mod.parse(line)
        if task and task.status ~= "x" then
          if mode == "due" and task.due then
            table.insert(tasks, { task = task, filepath = filepath, lnum = lnum })
          elseif mode == "wait" and task.wait then
            table.insert(tasks, { task = task, filepath = filepath, lnum = lnum })
          end
        end
      end
    end
  end

  local today_str      = os.date("%Y-%m-%d")
  local today_time     = utils.date_to_time(today_str)
  local week_end_time  = today_time + 7 * 24 * 60 * 60

  -- due モード用のグループ分け
  local overdue   = {}
  local by_date   = {}
  local later     = {}
  
  -- wait モード用のグループ分け
  local by_person = {}

  for _, entry in ipairs(tasks) do
    if mode == "due" then
      local due_time = utils.date_to_time(entry.task.due)
      if due_time < today_time then
        table.insert(overdue, entry)
      elseif due_time <= week_end_time then
        if not by_date[entry.task.due] then
          by_date[entry.task.due] = {}
        end
        table.insert(by_date[entry.task.due], entry)
      else
        table.insert(later, entry)
      end
    else
      -- wait モード
      local person = entry.task.wait
      if not by_person[person] then
        by_person[person] = {}
      end
      table.insert(by_person[person], entry)
    end
  end

  -- ソート
  local sorted_dates = {}
  local sorted_persons = {}
  
  if mode == "due" then
    for d in pairs(by_date) do table.insert(sorted_dates, d) end
    table.sort(sorted_dates)
    table.sort(overdue, function(a, b) return a.task.due < b.task.due end)
    table.sort(later,   function(a, b) return a.task.due < b.task.due end)
  else
    for p in pairs(by_person) do table.insert(sorted_persons, p) end
    table.sort(sorted_persons)
  end

  -- バッファ行 / ハイライト / ジャンプ先マップ
  local lines    = {}
  local hls      = {} -- { line_idx(0-based), hl_group }
  local line_map = {} -- line_idx(0-based) -> { filepath, original_line, lnum }

  local function add(text, hl_group, source)
    table.insert(lines, text)
    local idx = #lines - 1
    if hl_group then
      table.insert(hls, { idx, hl_group })
    end
    if source then
      line_map[idx] = source
    end
  end

  local function task_line(entry, prefix)
    local task = entry.task
    local line = (prefix or "  ▶ ") .. task.content
    if task.project then line = line .. " +" .. task.project end
    if task.context then line = line .. " " .. task.context end
    return line
  end

  local weekdays_jp = { "日", "月", "火", "水", "木", "金", "土" }

  local function date_label(date_str)
    local t    = utils.date_to_time(date_str)
    local diff = math.floor((t - today_time) / 86400)
    local mo   = tonumber(date_str:sub(6, 7))
    local d    = tonumber(date_str:sub(9, 10))
    local wday = tonumber(os.date("%w", t)) + 1
    local wd   = weekdays_jp[wday]
    if diff == 0 then
      return string.format(" 今日 (%d/%d %s)", mo, d, wd), "DiagnosticWarn"
    elseif diff == 1 then
      return string.format(" 明日 (%d/%d %s)", mo, d, wd), "DiagnosticInfo"
    else
      return string.format(" %d/%d %s (%d日後)", mo, d, wd, diff), "DiagnosticInfo"
    end
  end

  local sep = string.rep("─", 46)

  -- ヘッダー
  if mode == "due" then
    add(" Queue (Due)  " .. today_str, "Title")
  else
    add(" Queue (Wait) " .. today_str, "Title")
  end
  add(sep, "Comment")

  if mode == "due" then
    -- 期限切れ
    if #overdue > 0 then
      add("", nil)
      add(" 期限切れ", "DiagnosticError")
      add(sep, "Comment")
      for _, entry in ipairs(overdue) do
        local days_over = math.floor((today_time - utils.date_to_time(entry.task.due)) / 86400)
        add(
          task_line(entry, "  ⚠ ") .. string.format(" (%d日超過)", days_over),
          "DiagnosticError",
          { filepath = entry.filepath, original_line = entry.task.original_line, lnum = entry.lnum }
        )
      end
    end
    -- 今日〜7日後（タスクある日のみ）
    for _, date in ipairs(sorted_dates) do
      local label, hl = date_label(date)
      add("", nil)
      add(label, hl)
      add(sep, "Comment")
      for _, entry in ipairs(by_date[date]) do
        add(
          task_line(entry),
          nil,
          { filepath = entry.filepath, original_line = entry.task.original_line, lnum = entry.lnum }
        )
      end
    end

    -- それ以降
    if #later > 0 then
      add("", nil)
      add(" それ以降", "Comment")
      add(sep, "Comment")
      for _, entry in ipairs(later) do
        local mo = tonumber(entry.task.due:sub(6, 7))
        local d  = tonumber(entry.task.due:sub(9, 10))
        add(
          task_line(entry) .. string.format("  due:%d/%d", mo, d),
          "Comment",
          { filepath = entry.filepath, original_line = entry.task.original_line, lnum = entry.lnum }
        )
      end
    end

    -- タスクがひとつもない場合
    if #overdue == 0 and #sorted_dates == 0 and #later == 0 then
      add("", nil)
      add("  期限付きタスクはありません", "DiagnosticOk")
    end
  else
    -- wait モードの表示
    for _, person in ipairs(sorted_persons) do
      add("", nil)
      add(" " .. person .. " 待ち", "DiagnosticWarn")
      add(sep, "Comment")
      for _, entry in ipairs(by_person[person]) do
        add(
          task_line(entry),
          nil,
          { filepath = entry.filepath, original_line = entry.task.original_line, lnum = entry.lnum }
        )
      end
    end

    if #sorted_persons == 0 then
      add("", nil)
      add("  誰かの作業を待っているタスクはありません", "DiagnosticOk")
    end
  end

  -- フローティングウィンドウ
  local width  = math.min(math.floor(vim.o.columns * 0.65), 80)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
  local col    = math.floor((vim.o.columns - width) / 2)
  local row    = math.floor((vim.o.lines - height) / 2)

  -- 既存のgtodoフロートを閉じてから Queue を開く
  close_current_float()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"

  local queue_win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    col       = col,
    row       = row,
    style     = "minimal",
    border    = "rounded",
    title     = " Queue ",
    title_pos = "center",
  })
  register_float_win(queue_win)

  -- ハイライト適用
  local ns = vim.api.nvim_create_namespace("gtodo_queue")
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl[2], hl[1], 0, -1)
  end

  -- バッファローカルキーマップ
  vim.keymap.set('n', 'q',     ':q<CR>', { buffer = buf, noremap = true, silent = true })
  vim.keymap.set('n', '<Esc>', ':q<CR>', { buffer = buf, noremap = true, silent = true })
  
  -- Tab: Date view と Wait view をトグルする
  vim.keymap.set('n', '<Tab>', function()
    -- 現在の行のIDを記録 (filepath:lnum)
    local cursor_idx = vim.api.nvim_win_get_cursor(0)[1] - 1
    local current_source = line_map[cursor_idx]
    local target_id = current_source and (current_source.filepath .. ":" .. current_source.lnum) or nil
    
    local next_mode = mode == "due" and "wait" or "due"
    M.open_queue(next_mode, target_id)
  end, { buffer = buf, noremap = true, silent = true })

  -- Enter: カーソル行のタスクのファイル・行へジャンプ
  vim.keymap.set('n', '<CR>', function()
    local cursor_idx = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-based
    local source = line_map[cursor_idx]
    if not source then return end

    -- Queue ウィンドウを閉じてフローティングでファイルを開き該当行へ移動
    vim.cmd("q")
    local fname = vim.fn.fnamemodify(source.filepath, ":t:r"):upper()
    local _, new_win = M.open_float(source.filepath, fname)
    if source.lnum then
      pcall(vim.api.nvim_win_set_cursor, new_win, { source.lnum, 0 })
    end
  end, { buffer = buf, noremap = true, silent = true })

  -- もし前のビューから引き継いだターゲットがあれば復元
  if previous_target_id then
    for idx, source in pairs(line_map) do
      if source and (source.filepath .. ":" .. source.lnum) == previous_target_id then
        pcall(vim.api.nvim_win_set_cursor, queue_win, { idx + 1, 0 })
        break
      end
    end
  end
end

return M
