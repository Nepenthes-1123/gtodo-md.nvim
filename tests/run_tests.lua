-- 簡易テストランナー (plenary 不要)
-- busted 互換の describe / it / assert API を提供し、spec/ 以下のファイルを実行する。
-- 使用法: nvim --headless -u tests/minimal_init.lua -S tests/run_tests.lua

local results = { success = 0, fail = 0, errors = 0 }
local current_context = {}

-- ----------------------------------------------------------------
-- assert ライブラリ
-- ----------------------------------------------------------------
assert = {
  equals = function(expected, actual, msg)
    if expected ~= actual then
      error(string.format(
        "Expected %s but got %s%s",
        tostring(expected), tostring(actual),
        msg and (" -- " .. msg) or ""
      ), 2)
    end
  end,

  is_not_nil = function(val, msg)
    if val == nil then
      error(string.format(
        "Expected non-nil value%s",
        msg and (" -- " .. msg) or ""
      ), 2)
    end
  end,

  is_nil = function(val, msg)
    if val ~= nil then
      error(string.format(
        "Expected nil but got %s%s",
        tostring(val),
        msg and (" -- " .. msg) or ""
      ), 2)
    end
  end,

  truthy = function(val, msg)
    if not val then
      error(string.format(
        "Expected truthy but got %s%s",
        tostring(val),
        msg and (" -- " .. msg) or ""
      ), 2)
    end
  end,

  falsy = function(val, msg)
    if val then
      error(string.format(
        "Expected falsy but got %s%s",
        tostring(val),
        msg and (" -- " .. msg) or ""
      ), 2)
    end
  end,
}

-- ----------------------------------------------------------------
-- describe / it グローバル
-- ----------------------------------------------------------------
function describe(name, fn)
  table.insert(current_context, name)
  fn()
  table.remove(current_context)
end

function it(name, fn)
  local full_name = table.concat(current_context, " ") .. " " .. name
  local ok, err = pcall(fn)
  if ok then
    results.success = results.success + 1
    print(string.format("Success\t||\t%s", full_name))
  else
    results.fail = results.fail + 1
    print(string.format("Failed \t||\t%s", full_name))
    print(string.format("       \t  \t%s", tostring(err)))
  end
end

-- pending は無視
function pending(name, _)
  print(string.format("Pending\t||\t%s", table.concat(current_context, " ") .. " " .. name))
end

-- ----------------------------------------------------------------
-- spec ファイルの収集と実行
-- ----------------------------------------------------------------
local spec_dir = "tests/spec/"
local spec_files = vim.fn.glob(spec_dir .. "**/*_spec.lua", false, true)

print("\n========================================")
for _, file in ipairs(spec_files) do
  print("Testing: \t" .. file .. "\t")
  local ok, err = pcall(dofile, file)
  if not ok then
    results.errors = results.errors + 1
    print("Error in file: " .. tostring(err))
  end
  print("")
end

print(string.format("Success: \t%d\t", results.success))
print(string.format("Failed : \t%d\t", results.fail))
print(string.format("Errors : \t%d\t", results.errors))
print("========================================\t")

if results.fail > 0 or results.errors > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("quit")
end
