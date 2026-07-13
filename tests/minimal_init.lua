-- テスト用 minimal init
-- NOTE: このファイルはパス設定のみ。テスト実行ロジックは含めない。
-- plenary.test_harness が子プロセスを起動するときに -u として使用する。

-- プラグイン自身の lua/ をランタイムパスに追加
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- plenary のパスを追加
local plenary_path = vim.fn.stdpath("data") .. "/site/pack/core/opt/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:prepend(plenary_path)
end
