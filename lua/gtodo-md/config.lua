local M = {}

M.defaults = {
  data_dir = vim.fn.stdpath("data") .. "/gtodo-md", -- デフォルトはNeovimのデータディレクトリ
  use_default_keymaps = true,
  picker = "auto", -- ピッカー指定 ("auto" | "snacks" | "telescope" | "fzf-lua" | "builtin")
  keymap_prefix = "<Leader>t", -- キーマップ of プレフィックス接頭辞
  due_notification_cooldown = 1800, -- 期限切れ通知の最小間隔（秒）。デフォルト30分
  due_notification_persist = true, -- trueでNeovim終了後も時間を維持、falseで起動中のみ
  waiting_warning_days = 2, -- Waitingタスクの期限警告日数
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  -- ディレクトリが存在しない場合は作成
  local projects_dir = M.options.data_dir .. '/projects'
  if vim.fn.isdirectory(projects_dir) == 0 then
    vim.fn.mkdir(projects_dir, "p")
  end
end

return M
