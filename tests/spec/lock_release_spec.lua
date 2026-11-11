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

	-- ロックの中身は、取ったプロセスを見分ける印(プロセス ID と取得した時刻)。
	-- CLI/TUI (gtodo) も同じ形で書き、解放するときに自分の印かを確かめる。
	local function read_lock()
		local f = io.open(lock_path, "rb")
		if not f then
			return nil
		end
		local content = f:read("*a")
		f:close()
		return content
	end

	it("中身はプロセス ID で始まり、取得した時刻を添える", function()
		local content
		lock_mod.with_automation_lock(dir, function()
			content = read_lock()
		end)

		local pid, nanos = content:match("^(%d+) (%d+)$")
		assert.are.equal(tostring(vim.fn.getpid()), pid, content)
		assert.is_true(#nanos >= 18, content)
	end)

	-- 60 秒を超えて持った場合など、他のプロセスが残骸とみなして取り直したロックを
	-- 消すと、その相手の排他まで崩れる。以前は確かめずに消していた。
	it("他のプロセスに取り直されていたら消さない", function()
		local notes = {}
		local saved = vim.notify
		vim.notify = function(msg, level)
			table.insert(notes, { msg = tostring(msg), level = level })
		end
		local ok, err = pcall(lock_mod.with_automation_lock, dir, function()
			local f = assert(io.open(lock_path, "wb"))
			f:write("99999 1")
			f:close()
		end)
		vim.notify = saved
		assert(ok, err)

		assert.are.equal("99999 1", read_lock())
		assert.are.equal(1, #notes, vim.inspect(notes))
		assert.is_truthy(notes[1].msg:find("taken over", 1, true), notes[1].msg)
	end)

	-- 持っている間に 60 秒を超え、他のプロセスが残骸として消した場合。排他が崩れていたことを
	-- 知らせる(CLI も同じく知らせる)。
	it("既に消されていたら、失敗はさせずに知らせる", function()
		local notes = {}
		local saved = vim.notify
		vim.notify = function(msg, level)
			table.insert(notes, { msg = tostring(msg), level = level })
		end
		local ok, acquired = pcall(lock_mod.with_automation_lock, dir, function()
			os.remove(lock_path)
		end)
		vim.notify = saved
		assert(ok, acquired)

		assert.is_true(acquired)
		assert.is_nil(uv.fs_stat(lock_path))
		assert.are.equal(1, #notes, vim.inspect(notes))
		assert.is_truthy(notes[1].msg:find("removed by another process", 1, true), notes[1].msg)
	end)
end)
