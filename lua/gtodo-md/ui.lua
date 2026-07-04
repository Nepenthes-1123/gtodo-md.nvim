local M = {}
local config = require('gtodo-md.config')

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
      if line:match("^%s*-%s*%[x%]") then
        local tag = line:match("%+([%w%-]+)")
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
      "title: ",
      "tag: " .. project_tag,
      "created: " .. today,
      "due: ",
      "status: active",
      "members: []",
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
  local completed_count = 0
  
  -- done.md から過去の完了件数を取得 (高速キャッシュ経由)
  local done_path = data_dir .. "/done.md"
  local done_counts = get_done_project_counts(done_path)
  completed_count = completed_count + (done_counts[project_tag] or 0)
  
  -- inbox.md から該当プロジェクトのタスクを取得
  if vim.fn.filereadable(inbox_path) == 1 then
    local inbox_data = file_mod.read_todo_file(inbox_path)
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
    local todo_data = file_mod.read_todo_file(todo_path)
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
  
  local show_progress = config.options.enable_project_progress
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

-- Queue ビュー: due付き未完了タスクを日付グループ別に表示する
function M.open_queue()
  local data_dir = config.options.data_dir
  local file_mod = require('gtodo-md.file')

  -- inbox.md と todo.md から due: 付き未完了タスクを収集
  local source_files = {
    data_dir .. "/inbox.md",
    data_dir .. "/todo.md",
  }

  local tasks_with_due = {}

  for _, filepath in ipairs(source_files) do
    if vim.fn.filereadable(filepath) == 1 then
      local data = file_mod.read_todo_file(filepath)
      -- section_order + default セクションを網羅
      local seen = {}
      local all_sections = {}
      for _, sec_name in ipairs(data.section_order) do
        if not seen[sec_name] then
          seen[sec_name] = true
          table.insert(all_sections, sec_name)
        end
      end
      if data.sections["default"] and not seen["default"] then
        table.insert(all_sections, "default")
      end

      for _, sec_name in ipairs(all_sections) do
        local sec = data.sections[sec_name]
        if sec then
          for _, item in ipairs(sec) do
            if item.type == "task" and item.task.status ~= "x" and item.task.due then
              table.insert(tasks_with_due, item.task)
            end
          end
        end
      end
    end
  end

  -- 日付文字列 (YYYY-MM-DD) → os.time 変換ヘルパー
  local function date_to_time(date_str)
    return os.time({
      year  = tonumber(date_str:sub(1, 4)),
      month = tonumber(date_str:sub(6, 7)),
      day   = tonumber(date_str:sub(9, 10)),
      hour = 0, min = 0, sec = 0,
    })
  end

  local today_str      = os.date("%Y-%m-%d")
  local today_time     = date_to_time(today_str)
  local week_end_time  = today_time + 7 * 24 * 60 * 60

  -- グループ分け: 期限切れ / 今日〜7日後 / それ以降
  local overdue   = {}
  local by_date   = {}
  local later     = {}

  for _, task in ipairs(tasks_with_due) do
    local due_time = date_to_time(task.due)
    if due_time < today_time then
      table.insert(overdue, task)
    elseif due_time <= week_end_time then
      if not by_date[task.due] then
        by_date[task.due] = {}
      end
      table.insert(by_date[task.due], task)
    else
      table.insert(later, task)
    end
  end

  -- ソート
  local sorted_dates = {}
  for d in pairs(by_date) do
    table.insert(sorted_dates, d)
  end
  table.sort(sorted_dates)
  table.sort(overdue, function(a, b) return a.due < b.due end)
  table.sort(later,   function(a, b) return a.due < b.due end)

  -- バッファ行 / ハイライト構築ヘルパー
  local lines = {}
  local hls   = {} -- { line_idx(0-based), hl_group }

  local function add(text, hl_group)
    table.insert(lines, text)
    if hl_group then
      table.insert(hls, { #lines - 1, hl_group })
    end
  end

  local function task_line(task, prefix)
    local line = (prefix or "  \xe2\x96\xb6 ") .. task.content
    if task.project then line = line .. " +" .. task.project end
    if task.context then line = line .. " " .. task.context end
    return line
  end

  local weekdays_jp = { "\xe6\x97\xa5", "\xe6\x9c\x88", "\xe7\x81\xab", "\xe6\xb0\xb4", "\xe6\x9c\xa8", "\xe9\x87\x91", "\xe5\x9c\x9f" }

  local function date_label(date_str)
    local t    = date_to_time(date_str)
    local diff = math.floor((t - today_time) / 86400)
    local mo   = tonumber(date_str:sub(6, 7))
    local d    = tonumber(date_str:sub(9, 10))
    local wday = tonumber(os.date("%w", t)) + 1
    local wd   = weekdays_jp[wday]
    if diff == 0 then
      return string.format(" \xe4\xbb\x8a\xe6\x97\xa5 (%d/%d %s)", mo, d, wd), "DiagnosticWarn"
    elseif diff == 1 then
      return string.format(" \xe6\x98\x8e\xe6\x97\xa5 (%d/%d %s)", mo, d, wd), "DiagnosticInfo"
    else
      return string.format(" %d/%d %s (%d\xe6\x97\xa5\xe5\xbe\x8c)", mo, d, wd, diff), "DiagnosticInfo"
    end
  end

  local sep = string.rep("\xe2\x94\x80", 46)

  -- ヘッダー
  add(" Queue  " .. today_str, "Title")
  add(sep, "Comment")

  -- 期限切れ
  if #overdue > 0 then
    add("", nil)
    add(" \xe6\x9c\x9f\xe9\x99\x90\xe5\x88\x87\xe3\x82\x8c", "DiagnosticError")
    add(sep, "Comment")
    for _, task in ipairs(overdue) do
      local days_over = math.floor((today_time - date_to_time(task.due)) / 86400)
      add(task_line(task, "  \xe2\x9a\xa0 ") .. string.format(" (%d\xe6\x97\xa5\xe8\xb6\x85\xe9\x81\x8e)", days_over), "DiagnosticError")
    end
  end

  -- 今日〜7日後（タスクある日のみ）
  for _, date in ipairs(sorted_dates) do
    local label, hl = date_label(date)
    add("", nil)
    add(label, hl)
    add(sep, "Comment")
    for _, task in ipairs(by_date[date]) do
      add(task_line(task), nil)
    end
  end

  -- それ以降
  if #later > 0 then
    add("", nil)
    add(" \xe3\x81\x9d\xe3\x82\x8c\xe4\xbb\xa5\xe9\x99\x8d", "Comment")
    add(sep, "Comment")
    for _, task in ipairs(later) do
      local mo = tonumber(task.due:sub(6, 7))
      local d  = tonumber(task.due:sub(9, 10))
      add(task_line(task) .. string.format("  due:%d/%d", mo, d), "Comment")
    end
  end

  -- タスクがひとつもない場合
  if #overdue == 0 and #sorted_dates == 0 and #later == 0 then
    add("", nil)
    add("  \xe6\x9c\x9f\xe9\x99\x90\xe4\xbb\x98\xe3\x81\x8d\xe3\x82\xbf\xe3\x82\xb9\xe3\x82\xaf\xe3\x81\xaf\xe3\x81\x82\xe3\x82\x8a\xe3\x81\xbe\xe3\x81\x9b\xe3\x82\x93", "DiagnosticOk")
  end

  -- フローティングウィンドウ
  local width  = math.min(math.floor(vim.o.columns * 0.65), 80)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
  local col    = math.floor((vim.o.columns - width) / 2)
  local row    = math.floor((vim.o.lines - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"

  vim.api.nvim_open_win(buf, true, {
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

  -- ハイライト適用
  local ns = vim.api.nvim_create_namespace("gtodo_queue")
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl[2], hl[1], 0, -1)
  end

  -- バッファローカルキーマップ
  vim.keymap.set('n', 'q',     ':q<CR>', { buffer = buf, noremap = true, silent = true })
  vim.keymap.set('n', '<Esc>', ':q<CR>', { buffer = buf, noremap = true, silent = true })
end

return M

