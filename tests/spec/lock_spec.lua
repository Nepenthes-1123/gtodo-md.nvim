local lock_mod = require("gtodo-md.lock")
local uv = vim.uv or vim.loop

describe("lock.with_write_lock", function()
	local data_dir
	local lock_path

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		lock_path = data_dir .. "/.gtodo.lock"
	end)

	after_each(function()
		vim.fn.delete(lock_path)
		vim.fn.delete(data_dir, "rf")
	end)

	it("ロックを取得して fn を実行し、完了後にロックを解放する", function()
		local called = false
		local acquired = lock_mod.with_write_lock(data_dir, function()
			called = true
		end)

		assert.is_true(acquired)
		assert.is_true(called)
		assert.are.same(0, vim.fn.filereadable(lock_path))
	end)

	it(
		"既にロックファイルが存在する場合、fn を実行せず false を返す(待機しない)",
		function()
			vim.fn.writefile({ "12345" }, lock_path)

			local called = false
			local acquired = lock_mod.with_write_lock(data_dir, function()
				called = true
			end)

			assert.is_false(acquired)
			assert.is_false(called)
			-- 他インスタンスのロックを勝手に消さないこと
			assert.are.same(1, vim.fn.filereadable(lock_path))
		end
	)

	it(
		"fn がエラーを投げても、ロックは解放され呼び出し元にはエラーを伝播しない",
		function()
			local acquired = lock_mod.with_write_lock(data_dir, function()
				error("boom")
			end)

			assert.is_true(acquired)
			assert.are.same(0, vim.fn.filereadable(lock_path))
		end
	)

	it("60秒を超えて残留した古いロックは無効化され再取得できる", function()
		vim.fn.writefile({ "99999" }, lock_path)
		-- mtime を61秒前に偽装する
		local t = os.time() - 61
		uv.fs_utime(lock_path, t, t)

		local called = false
		local acquired = lock_mod.with_write_lock(data_dir, function()
			called = true
		end)

		assert.is_true(acquired)
		assert.is_true(called)
	end)

	it("60秒以内の新しいロックは無効化されない", function()
		vim.fn.writefile({ "99999" }, lock_path)
		local t = os.time() - 10
		uv.fs_utime(lock_path, t, t)

		local called = false
		local acquired = lock_mod.with_write_lock(data_dir, function()
			called = true
		end)

		assert.is_false(acquired)
		assert.is_false(called)
	end)
end)
