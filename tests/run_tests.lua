-- テスト実行スクリプト
-- 使用法: nvim --headless -u tests/minimal_init.lua -S tests/run_tests.lua
-- minimal_init.lua でパス設定を行い、このスクリプトでテストを実行する。

require("plenary.test_harness").test_directory("tests/spec/", {
  minimal_init = "tests/minimal_init.lua",
})
