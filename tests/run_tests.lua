local ok, harness = pcall(require, "plenary.test_harness")
if not ok then
  print("Failed to load plenary.nvim. Please ensure it is in runtimepath.")
  vim.cmd("cquit 1")
end

-- Plenary のテストランナーを呼び出し
-- 内部で別プロセスを立ち上げてテストを実行し、適切に exit(0 or 1) します。
harness.test_directory("tests/spec/", {
  minimal_init = "tests/minimal_init.lua",
})
