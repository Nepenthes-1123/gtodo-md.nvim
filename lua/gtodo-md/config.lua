local M = {}

M.defaults = {
  data_dir = vim.fn.stdpath("data") .. "/todo", -- デフォルトはNeovimのデータディレクトリ
  use_default_keymaps = true,
  picker = "auto", -- ピッカー指定 ("auto" | "snacks" | "telescope" | "fzf-lua" | "builtin")
  keymap_prefix = "<Leader>t", -- キーマップのプレフィックス接頭辞
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
