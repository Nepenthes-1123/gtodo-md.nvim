if vim.g.loaded_gtodo_md_nvim then
  return
end
vim.g.loaded_gtodo_md_nvim = 1

-- ユーザー向けコマンドの定義
vim.api.nvim_create_user_command("GtodoSort", function()
  local config = require('gtodo-md.config')
  if not config.options.data_dir then
    require('gtodo-md').setup({})
  end
  local todo_path = config.options.data_dir .. "/todo.md"
  require('gtodo-md.file').sort_todo_file(todo_path)
  vim.notify("Todo sorted manually.", vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("GtodoSearch", function()
  local config = require('gtodo-md.config')
  if not config.options.data_dir then
    require('gtodo-md').setup({})
  end
  require('gtodo-md.ui').search_tasks()
end, {})
