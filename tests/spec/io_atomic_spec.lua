-- #125 回帰テスト: write_lines のディスク書き込みが真のアトミック置換になったこと。
--
-- 旧実装は `path .. ".tmp"` という**プロセス間で共有される**一時ファイル名を使い、
-- vim.fn.rename() で置換していた。Neovim の vim_rename() は rename の前に
-- os_remove(to) を実行するため、置換先が一瞬ディスクから消える窓があった。

local io_mod = require("gtodo-md.io")
local uv = vim.uv or vim.loop

describe("io の書き込みはアトミックである", function()
	local dir
	local path

	before_each(function()
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		path = dir .. "/todo.md"
	end)

	after_each(function()
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == path then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(dir, "rf")
	end)

	-- ディレクトリ内の一時ファイル(先頭ドット + 末尾 .tmp)を列挙する
	local function list_tmp()
		local found = {}
		local scanner = uv.fs_scandir(dir)
		if not scanner then
			return found
		end
		while true do
			local name = uv.fs_scandir_next(scanner)
			if not name then
				break
			end
			if name:match("^%..+%.tmp$") then
				table.insert(found, name)
			end
		end
		return found
	end

	it("書き込み後に一時ファイルが残らない", function()
		io_mod.write_lines(path, { "# Todo", "", "- [ ] タスク" })
		assert.are.same({}, list_tmp())
		assert.are.same({ "# Todo", "", "- [ ] タスク" }, vim.fn.readfile(path))
	end)

	it("旧実装が使っていた共有名 <path>.tmp は作られない", function()
		io_mod.write_lines(path, { "# Todo" })
		assert.is_nil(uv.fs_stat(path .. ".tmp"))
	end)

	it("一時ファイル名は呼び出しごとに異なる", function()
		-- 一時ファイルは rename 後に消えるため、名前そのものは観測できない。
		-- 代わりに atomic_write を連続で呼び、後続の書き込みが EEXIST で
		-- 失敗しない(＝名前を使い回していない)ことを確認する。
		for i = 1, 5 do
			local ok, err = io_mod.atomic_write(path, "run " .. i .. "\n")
			assert.is_true(ok, tostring(err))
		end
		assert.are.same({ "run 5" }, vim.fn.readfile(path))
		assert.are.same({}, list_tmp())
	end)

	it("書き込みに失敗すると write_lines は例外を投げる", function()
		-- 存在しないディレクトリ配下は一時ファイルの作成自体が失敗する
		local bad = dir .. "/no_such_dir/todo.md"
		local ok, err = pcall(io_mod.write_lines, bad, { "x" })
		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("failed to write", 1, true))
	end)

	it("書き込みに失敗した場合、元のファイルは変更されない", function()
		io_mod.write_lines(path, { "original" })

		-- ディレクトリを読み取り専用にはできない環境があるため、
		-- 置換先をディレクトリにして rename を失敗させる
		local blocked = dir .. "/blocked.md"
		vim.fn.mkdir(blocked, "p")
		local ok = io_mod.atomic_write(blocked, "should not land")
		assert.is_nil(ok)
		-- 失敗しても一時ファイルは残らない
		assert.are.same({}, list_tmp())
		-- 別ファイルである path は無傷
		assert.are.same({ "original" }, vim.fn.readfile(path))
	end)

	it("atomic_write は失敗を例外ではなく nil, err で返す", function()
		local ok, err = io_mod.atomic_write(dir .. "/no_such_dir/x.md", "data")
		assert.is_nil(ok)
		assert.is_string(err)
	end)

	if uv.os_uname().sysname ~= "Windows_NT" then
		it("既存ファイルのパーミッションが保たれる (POSIX)", function()
			io_mod.write_lines(path, { "a" })
			uv.fs_chmod(path, tonumber("644", 8))
			local before = uv.fs_stat(path).mode

			io_mod.write_lines(path, { "a", "b" })

			assert.are.equal(before, uv.fs_stat(path).mode)
		end)

		it("シンボリックリンクはリンクのまま保たれ、実体が書き換わる", function()
			local real = dir .. "/real.md"
			local link = dir .. "/link.md"
			io_mod.write_lines(real, { "before" })
			assert.is_true(uv.fs_symlink(real, link) ~= nil)

			io_mod.write_lines(link, { "after" })

			-- リンクが実体ファイルへ置き換わっていないこと
			assert.are.equal("link", uv.fs_lstat(link).type)
			-- 実体側に書かれていること
			assert.are.same({ "after" }, vim.fn.readfile(real))
		end)
	end
end)

describe("io.ensure_files の一時ファイル掃除", function()
	local dir
	local config = require("gtodo-md.config")
	local saved_data_dir

	before_each(function()
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		config.options.data_dir = dir
	end)

	after_each(function()
		config.options.data_dir = saved_data_dir
		vim.fn.delete(dir, "rf")
	end)

	it("TTL を超えた残骸は削除され、新しいものは残る", function()
		local stale = dir .. "/.todo.md.99999.1.tmp"
		local fresh = dir .. "/.todo.md.99999.2.tmp"
		vim.fn.writefile({ "x" }, stale)
		vim.fn.writefile({ "x" }, fresh)

		-- 25時間前に見せかける (TTL は 24 時間)
		local old = os.time() - 25 * 60 * 60
		uv.fs_utime(stale, old, old)

		io_mod.ensure_files()

		assert.is_nil(uv.fs_stat(stale))
		assert.is_truthy(uv.fs_stat(fresh))
	end)

	it("PID が一致するかどうかで判定しない", function()
		-- 掃除は mtime だけで判定する。PID は OS に再利用されるため、
		-- 名前に自分の PID を含む残骸を特別扱いすると永久に消えなくなる。
		local own = string.format("%s/.todo.md.%d.1.tmp", dir, vim.fn.getpid())
		vim.fn.writefile({ "x" }, own)
		local old = os.time() - 25 * 60 * 60
		uv.fs_utime(own, old, old)

		io_mod.ensure_files()

		assert.is_nil(uv.fs_stat(own))
	end)

	it("一時ファイルでない .md は消さない", function()
		io_mod.ensure_files()
		assert.is_truthy(uv.fs_stat(dir .. "/todo.md"))
		assert.is_truthy(uv.fs_stat(dir .. "/inbox.md"))
	end)
end)
