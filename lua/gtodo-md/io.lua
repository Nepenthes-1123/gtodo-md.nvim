local M = {}
local task_mod = require('gtodo-md.task')
local config = require('gtodo-md.config')

-- 指定されたパスのバッファが存在し、ロードされているか確認
local function get_buf_by_name(path)
  local realpath = vim.fn.fnamemodify(path, ":p")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local bufname = vim.api.nvim_buf_get_name(buf)
      if vim.fn.fnamemodify(bufname, ":p") == realpath then
        return buf
      end
    end
  end
  return nil
end

-- ファイルまたはバッファから行リストを読み込む
function M.read_lines(path)
  local buf = get_buf_by_name(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    local lines = {}
    local f = io.open(path, "r")
    if not f then return lines end
    for line in f:lines() do
      table.insert(lines, line)
    end
    f:close()
    return lines
  end
end

function M.format_buffer(bufnr)
  pcall(function()
    if package.loaded["conform"] then
      require("conform").format({ bufnr = bufnr, async = false })
    elseif vim.fn.exists(":Neoformat") == 2 then
      vim.cmd("Neoformat")
    elseif vim.fn.exists(":Format") == 2 then
      vim.cmd("Format")
    else
      vim.lsp.buf.format({ bufnr = bufnr, async = false })
    end
  end)
end

-- 差分のみを更新し、Extmarksの破壊を防ぐ
local function update_lines_incrementally(buf, new_lines)
  local old_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_idx = 1
  while start_idx <= #old_lines and start_idx <= #new_lines and old_lines[start_idx] == new_lines[start_idx] do
    start_idx = start_idx + 1
  end
  
  local end_old = #old_lines
  local end_new = #new_lines
  while end_old >= start_idx and end_new >= start_idx and old_lines[end_old] == new_lines[end_new] do
    end_old = end_old - 1
    end_new = end_new - 1
  end
  
  if start_idx > #old_lines and start_idx > #new_lines then
    return -- 変更なし
  end
  
  local replacement = {}
  for i = start_idx, end_new do
    table.insert(replacement, new_lines[i])
  end
  
  vim.api.nvim_buf_set_lines(buf, start_idx - 1, end_old, false, replacement)
end

-- ファイルまたはバッファに行リストを書き込む
function M.write_lines(path, lines)
  local buf = get_buf_by_name(path)
  
  if buf then
    local was_modified = vim.bo[buf].modified
    update_lines_incrementally(buf, lines)
    
    if not was_modified then
      -- バックグラウンドタイマーやプログラムによる自動更新でバッファがサイレントに汚染されるのを防ぐため、元々クリーンだった場合は即座に保存する
      pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("silent! write") end)
    end
  else
    local tmp_path = path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if f then
      for _, line in ipairs(lines) do
        f:write(line .. "\n")
      end
      f:close()
      vim.fn.rename(tmp_path, path)
    end
  end
end

-- 指定ファイルをパースして、セクションごとの行のリストにする
function M.read_todo_file(filepath)
  local lines = M.read_lines(filepath)
  if #lines == 0 then
    return { sections = {}, section_order = {}, header = {} }
  end
  return M.parse_markdown(lines)
end

-- data.sections[sec] の items を返すヘルパー（フラット互換のための内部ユーティリティ）
-- 現在の実装では sections[sec] は常にネスト構造なので、そのまま .items を返す
function M.get_section_items(sec_data)
  if type(sec_data) == "table" and sec_data.items ~= nil then
    return sec_data.items
  end
  -- 旧フラット構造への互換（本来到達しないが安全ガード）
  return sec_data or {}
end

-- 空のセクションデータを生成するヘルパー
local function new_section()
  return { items = {}, subsections = {} }
end

function M.parse_markdown(lines)
  local data = {
    header = {},
    sections = {},
    section_order = {},
  }

  local current_section = "default"
  data.sections[current_section] = new_section()

  -- 現在のサブセクション状態
  -- nil のときはトップレベル（### なし）、文字列のときはそのサブセクション配下
  local current_subsection = nil

  local header_done = false

  for _, line in ipairs(lines) do
    -- ## セクション境界
    local sec_name = line:match("^##%s+(.*)$")
    -- ### サブセクション境界（## に続く # で始まるものは除外済みなので ^### で OK）
    local subsec_name = (not sec_name) and line:match("^###%s+(.-)%s*$") or nil
    local task = task_mod.parse(line)

    if sec_name then
      sec_name = vim.trim(sec_name)
      current_section = sec_name
      current_subsection = nil -- 新セクションでサブセクションをリセット
      if not data.sections[current_section] then
        data.sections[current_section] = new_section()
        table.insert(data.section_order, current_section)
      end
      header_done = true
    elseif subsec_name then
      -- ### 見出し: 現在のセクション配下に新しいサブセクションを追加
      current_subsection = subsec_name
      local sec = data.sections[current_section]
      -- 同名サブセクションが既に存在する場合は再利用しない（順序保持のため新規追加）
      table.insert(sec.subsections, { name = subsec_name, items = {} })
      header_done = true
    elseif task then
      header_done = true
    end

    if not header_done then
      table.insert(data.header, line)
    elseif not sec_name and not subsec_name then
      local sec = data.sections[current_section]
      -- 挿入先: サブセクション配下 or トップレベル items
      local target_items
      if current_subsection then
        -- 末尾のサブセクション（最後に追加されたもの）に挿入
        local sub = sec.subsections[#sec.subsections]
        target_items = sub and sub.items or sec.items
      else
        target_items = sec.items
      end

      if task then
        table.insert(target_items, { type = "task", task = task, line = line })
      else
        -- 空行はソート時のインデックスズレやMarkdownリスト分断の原因になるため無視する
        if vim.trim(line) ~= "" then
          table.insert(target_items, { type = "text", line = line })
        end
      end
    end
  end

  return data
end

-- items リスト（task/text のフラット配列）を行リストに変換するローカルヘルパー
local function items_to_lines(items, lines)
  for _, item in ipairs(items) do
    if item.type == "task" then
      table.insert(lines, task_mod.serialize(item.task))
    else
      local text = item.line
      if vim.trim(text) == "" then
        if #lines > 0 and vim.trim(lines[#lines]) ~= "" then
          table.insert(lines, text)
        end
      else
        table.insert(lines, text)
      end
    end
  end
end

-- パースしたデータを書き戻す
function M.write_todo_file(filepath, data)
  local lines = {}

  for _, l in ipairs(data.header) do
    table.insert(lines, l)
  end

  -- default セクション（## なし領域）の書き出し
  local default_sec = data.sections["default"]
  local default_items = default_sec and M.get_section_items(default_sec) or {}
  if #default_items > 0 then
    if #lines > 0 and lines[#lines] ~= "" then
      table.insert(lines, "")
    end
    items_to_lines(default_items, lines)
  end

  for _, sec in ipairs(data.section_order) do
    if #lines > 0 and lines[#lines] ~= "" then
      table.insert(lines, "")
    end
    table.insert(lines, "## " .. sec)
    table.insert(lines, "")

    local sec_data = data.sections[sec] or new_section()

    -- トップレベル items の書き出し
    items_to_lines(M.get_section_items(sec_data), lines)

    -- サブセクションの書き出し
    local subsections = (type(sec_data) == "table" and sec_data.subsections) or {}
    for _, sub in ipairs(subsections) do
      -- サブセクション見出しの前に空行を入れる（直前が空でなければ）
      if #lines > 0 and lines[#lines] ~= "" then
        table.insert(lines, "")
      end
      table.insert(lines, "### " .. sub.name)
      table.insert(lines, "")
      items_to_lines(sub.items, lines)
    end
  end

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  table.insert(lines, "")

  M.write_lines(filepath, lines)
  return true
end

function M.ensure_files()
  local data_dir = config.get("data_dir")
  local files = {
    { path = data_dir .. "/inbox.md", title = "# Inbox\n" },
    { path = data_dir .. "/todo.md", title = string.format("# Todo\n\n## %s\n\n## %s\n\n## %s\n\n## %s", config.sections.TODAY, config.sections.NEXT, config.sections.WAITING, config.sections.SOMEDAY) },
    { path = data_dir .. "/done.md", title = "# Done\n" },
    { path = data_dir .. "/cancelled.md", title = "# Cancelled\n" },
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

return M
