-- with_automation_lock が例外通過時にもロックを解放することを固定する。
--
-- write_lines が失敗時に error を投げるようになったため、この不変条件が破れると
-- 書き込み失敗のたびにロックがリークする。ロックは取得失敗時に待機・リトライせず
-- 即座に諦める仕様のため、リークすると stale 判定までの 60 秒間、全インスタンスの
-- 自動処理が通知も無くスキップされる。

local lock_mod = require("gtodo-md.lock")
local uv = vim.uv or vim.loop

describe("lock.with_automation_lock", function()
	local dir
	local lock_path

	before_each(function()
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		lock_path = dir .. "/.gtodo.lock"
	end)

	after_each(function()
		vim.fn.delete(dir, "rf")
	end)

	it("本体が error を投げてもロックファイルが残らない", function()
		local acquired = lock_mod.with_automation_lock(dir, function()
			error("boom", 0)
		end)

		assert.is_true(acquired)
		assert.is_nil(uv.fs_stat(lock_path))
	end)

	it("例外の直後でも同じロックを取得できる", function()
		lock_mod.with_automation_lock(dir, function()
			error("boom", 0)
		end)

		local ran = false
		local acquired = lock_mod.with_automation_lock(dir, function()
			ran = true
		end)

		assert.is_true(acquired)
		assert.is_true(ran)
		assert.is_nil(uv.fs_stat(lock_path))
	end)

	it("正常終了時もロックファイルが残らない", function()
		local acquired = lock_mod.with_automation_lock(dir, function() end)

		assert.is_true(acquired)
		assert.is_nil(uv.fs_stat(lock_path))
	end)
end)
