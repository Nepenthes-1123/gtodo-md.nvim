local M = {}

-- タスク行をパースしてテーブルにする
-- タスクでない行は nil を返す
function M.parse(line)
  local indent, status, rest = line:match("^(%s*)%-%s*%[([ xX])%]%s*(.*)$")
  if not status then
    return nil
  end
  -- 大文字Xを小文字に正規化
  status = status:lower()

  local task = {
    indent = indent,
    status = status, -- " " (未完了) or "x" (完了)
    original_line = line,
  }

  local text = rest

  local function extract_field(pattern)
    local start_idx, end_idx, val = text:find(pattern)
    if start_idx then
      -- グループ指定がない場合はマッチ全体を返す
      if not val then
        val = text:sub(start_idx, end_idx)
      end
      text = text:sub(1, start_idx - 1) .. text:sub(end_idx + 1)
    end
    return val
  end

  -- フィールド抽出
  task.completed_at = extract_field("completed_at:(%d%d%d%d%-%d%d%-%d%d)")
  task.done = extract_field("done:(%d%d%d%d%-%d%d%-%d%d)")
  task.cancelled = extract_field("cancelled:(%d%d%d%d%-%d%d%-%d%d)")
  task.from = extract_field("from:(%w+)")
  -- due: は英数字・ハイフン・スラッシュ・プラスのみ許容（記号・URLを弾く）
  local raw_due = extract_field("due:([%w%-/%+]+)")
  if raw_due then
    local normalized = require('gtodo-md.utils').parse_due_date(raw_due)
    task.due = normalized or raw_due
  end
  task.created = extract_field("created:(%d%d%d%d%-%d%d%-%d%d)")

  -- @context: 空白区切りが優先。行頭の@のみ fallback（メールアドレス等の誤検知を防ぐ）
  task.context = extract_field("%s+(@[%w%-_/%.]+)") or extract_field("^(@[%w%-_/%.]+)")

  -- +project-name: 空白+プラスが優先。行頭の+のみ fallback（C++等の誤検知を防ぐ）
  task.project = extract_field("%s%+([%w%-_/%.]+)") or extract_field("^%+([%w%-_/%.]+)")

  -- wait:タグの抽出（句読点や括弧を除外）
  task.wait = extract_field("wait:([^%s　。、%.,%(%)（）]+)")

  -- 余分なスペースのトリミング
  text = text:gsub("%s+", " ")
  task.content = vim.trim(text)

  return task
end

-- タスクのテーブルから文字列表現を生成する
function M.serialize(task)
  local parts = {}
  table.insert(parts, string.format("%s- [%s] %s", task.indent or "", task.status or " ", task.content or ""))
  
  if task.project and task.project ~= "" then
    table.insert(parts, "+" .. task.project)
  end
  
  if task.context and task.context ~= "" then
    local ctx = task.context
    if not ctx:match("^@") then
      ctx = "@" .. ctx
    end
    table.insert(parts, ctx)
  end
  
  if task.due and task.due ~= "" then
    table.insert(parts, "due:" .. task.due)
  end
  
  if task.created and task.created ~= "" then
    table.insert(parts, "created:" .. task.created)
  end
  
  if task.wait and task.wait ~= "" then
    table.insert(parts, "wait:" .. task.wait)
  end
  
  if task.completed_at and task.completed_at ~= "" then
    table.insert(parts, "completed_at:" .. task.completed_at)
  end

  if task.done and task.done ~= "" then
    table.insert(parts, "done:" .. task.done)
  end

  if task.cancelled and task.cancelled ~= "" then
    table.insert(parts, "cancelled:" .. task.cancelled)
  end

  if task.from and task.from ~= "" then
    table.insert(parts, "from:" .. task.from)
  end

  return table.concat(parts, " ")
end

-- 新規タスクの追加または編集 (ハイブリッド対話メニュー方式)
function M.prompt_task(initial_task, callback)
  local task = initial_task or {}
  
  local function input(opts, on_confirm)
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.input then
      local merged_opts = vim.tbl_deep_extend("force", opts, {
        win = {
          relative = "editor",
        }
      })
      snacks.input(merged_opts, on_confirm)
    else
      vim.ui.input(opts, on_confirm)
    end
  end

  -- 既存プロジェクト一覧の取得 (最近更新された順)
  local function get_projects()
    local proj_list = {}
    local data_dir = require('gtodo-md.config').options.data_dir
    local projects_dir = data_dir .. "/projects"
    if vim.fn.isdirectory(projects_dir) == 1 then
      local files = vim.fn.globpath(projects_dir, "*.md", false, true)
      local temp = {}
      for _, file in ipairs(files) do
        local name = vim.fn.fnamemodify(file, ":t:r")
        local mtime = vim.fn.getftime(file)
        table.insert(temp, { name = name, mtime = mtime })
      end
      table.sort(temp, function(a, b)
        return a.mtime > b.mtime
      end)
      for _, item in ipairs(temp) do
        table.insert(proj_list, item.name)
      end
    end
    return proj_list
  end

  local function create_project_file(project_tag)
    require('gtodo-md.utils').create_project_file(project_tag)
  end

  -- Step 1: 説明
  input({
    prompt = "Description (required): ",
    default = task.content or ""
  }, function(content)
    if not content or vim.trim(content) == "" then
      if not initial_task then
        vim.notify("Description is required to create a task.", vim.log.levels.ERROR)
        return
      else
        return -- 編集時はキャンセル
      end
    end
    task.content = vim.trim(content)

    -- Step 2: Due Date 手入力 (中央表示の Snacks.input 経由)
    local default_due = task.due or ""
    input({
      prompt = "Due date (e.g. today, tomorrow, +3d, 2026-07-02) [Skip]: ",
      default = default_due
    }, function(due_input)
      local final_due = nil
      if due_input and vim.trim(due_input) ~= "" then
        due_input = vim.trim(due_input)
        local normalized = require('gtodo-md.utils').parse_due_date(due_input)
        if not normalized then
          vim.notify("Invalid date format. Skipping due date.", vim.log.levels.WARN)
        else
          final_due = normalized
        end
      end
      task.due = final_due
      
      -- Step 3: Project 選択 (New Project... を常に上部に配置)
      local projects = get_projects()
      local proj_options = {}
      local default_proj_opt = "[Skip]"

      if task.project and task.project ~= "" then
        default_proj_opt = task.project
        table.insert(proj_options, task.project)
      end
      
      table.insert(proj_options, "[Skip]")
      table.insert(proj_options, "New Project...")
      
      for _, p in ipairs(projects) do
        if p ~= task.project then
          table.insert(proj_options, p)
        end
      end

      vim.ui.select(proj_options, {
        prompt = "Select Project:",
        default = default_proj_opt
      }, function(proj_choice)
        if not proj_choice then return end

        local function proceed_with_project(final_project)
          task.project = final_project

          -- Step 4: Context 選択
          local default_ctx_opt = "[Skip]"
          if task.context and task.context ~= "" then
            default_ctx_opt = task.context
            if not default_ctx_opt:match("^@") then
              default_ctx_opt = "@" .. default_ctx_opt
            end
          end

          local ctx_options = {}
          if default_ctx_opt ~= "[Skip]" then
            table.insert(ctx_options, default_ctx_opt)
          end
          table.insert(ctx_options, "[Skip]")
          
          for _, c in ipairs({ "@15", "@30", "@60", "@long" }) do
            if c ~= default_ctx_opt then
              table.insert(ctx_options, c)
            end
          end

          vim.ui.select(ctx_options, {
            prompt = "Select Context:",
            default = default_ctx_opt,
            format_item = function(item)
              if item == "[Skip]" then return item end
              local meaning = ""
              if item == "@15" then meaning = " (15 min)"
              elseif item == "@30" then meaning = " (30 min)"
              elseif item == "@60" then meaning = " (60 min)"
              elseif item == "@long" then meaning = " (>60 min)"
              end
              return item .. meaning
            end
          }, function(ctx_choice)
            if not ctx_choice then return end
            if ctx_choice == "[Skip]" then
              task.context = nil
            else
              task.context = ctx_choice
            end

            -- 最終決定
            if not task.created then
              task.created = os.date("%Y-%m-%d")
            end
            if not task.status then
              task.status = " "
            end
            
            callback(task)
          end)
        end

        -- プロジェクト選択判定
        if proj_choice == "New Project..." then
          input({
            prompt = "New Project Name (e.g. site-renewal): ",
            default = ""
          }, function(new_proj)
            if not new_proj or vim.trim(new_proj) == "" then
              proceed_with_project(nil)
            else
              new_proj = vim.trim(new_proj):gsub("^%+", "")
              create_project_file(new_proj)
              proceed_with_project(new_proj)
            end
          end)
        elseif proj_choice == "[Skip]" then
          proceed_with_project(nil)
        else
          proceed_with_project(proj_choice)
        end
      end)
    end)
  end)
end

return M
