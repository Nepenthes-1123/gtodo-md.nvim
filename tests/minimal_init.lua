-- テスト用 minimal init
-- NOTE: このファイルはパス設定のみ。テスト実行ロジックは含めない。
-- plenary.test_harness が子プロセスを起動するときに -u として使用する。

-- プラグイン自身の lua/ を最優先で package.path と runtimepath に追加
local script_path = debug.getinfo(1, "S").source:sub(2)
local worktree_root = vim.fn.fnamemodify(script_path, ":p:h:h"):gsub("\\", "/")
package.path = worktree_root .. "/lua/?.lua;" .. worktree_root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:prepend(worktree_root)

for k, _ in pairs(package.loaded) do
	if k:match("^gtodo%-md") then
		package.loaded[k] = nil
	end
end

-- スワップファイルを無効化する。
-- plenary の test_directory は複数の Neovim を並列で起動するため、名前付き
-- バッファを作るスペックが同時に走ると、各プロセスが同じスワップ用ディレクトリ
-- (stdpath("state")/swap) を同時に作ろうとして E303 で落ちることがある。
-- ヘッダレスのテストにクラッシュ復旧は不要なので、そもそも作らせない。
vim.opt.swapfile = false

-- 利用者自身の共有設定 (GTODO_DATA_DIR・config.json) をテストに読ませない。
-- 読ませると、data_dir を渡さない setup() が利用者の実データを対象にし、
-- data_dir を渡す setup() も食い違いの警告を出して、通知を確かめるテストが落ちる。
-- 空の config.json を GTODO_CONFIG で指し、既定の場所のファイルを読ませないようにする。
vim.env.GTODO_DATA_DIR = nil
local empty_config = vim.fn.tempname() .. "-gtodo-config.json"
vim.fn.writefile({ "{}" }, empty_config)
vim.env.GTODO_CONFIG = empty_config

-- plenary のパスを追加
local plenary_path = vim.fn.stdpath("data") .. "/site/pack/core/opt/plenary.nvim"
local local_plenary = vim.fn.getcwd() .. "/plenary"

if vim.fn.isdirectory(plenary_path) == 1 then
	vim.opt.runtimepath:prepend(plenary_path)
elseif vim.fn.isdirectory(local_plenary) == 1 then
	vim.opt.runtimepath:prepend(local_plenary)
else
	print("Warning: plenary.nvim not found. Tests may fail if plenary is required.")
end
