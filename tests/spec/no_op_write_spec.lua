-- 内容が変わらない書き込みはディスクへ届かせない。
--
-- 自動処理(sort_todo_file 等)は結果が同じでも毎回 write_todo_file を呼ぶ。
-- そのまま書くと mtime が動き、同じ data_dir を開いている全インスタンスが
-- checktime でリロードする。リロードは未保存編集の破棄・スタンプのずれ・
-- rename の窓を伴うため、無意味に踏ませない。

local io_mod = require("gtodo-md.io")
local uv = vim.uv or vim.loop

-- 「書かれたら必ず mtime が変わる」状態を作る。書き込み直後の mtime は
-- 現在時刻になるため、基準を過去へずらしておけば sec の比較だけで判定できる。
local function backdate(path)
	local st = uv.fs_stat(path)
	uv.fs_utime(path, st.atime.sec - 100, st.mtime.sec - 100)
	return uv.fs_stat(path).mtime.sec
end

describe("内容が変わらない書き込み", function()
	local path

	before_each(function()
		path = vim.fn.tempname() .. "_todo.md"
	end)

	after_each(function()
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == path then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(path)
	end)

	it("write_lines は同じ内容ならディスクへ書かない", function()
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
		local before = backdate(path)

		io_mod.read_lines(path)
		io_mod.write_lines(path, { "# Todo", "- [ ] a" })

		assert.are.equal(before, uv.fs_stat(path).mtime.sec, "内容が同じなのに書き込んでいる")
		assert.are.same({ "# Todo", "- [ ] a" }, vim.fn.readfile(path))
	end)

	it("write_lines は内容が違えば書く", function()
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
		local before = backdate(path)

		io_mod.read_lines(path)
		io_mod.write_lines(path, { "# Todo", "- [ ] b" })

		assert.are_not.equal(before, uv.fs_stat(path).mtime.sec)
		assert.are.same({ "# Todo", "- [ ] b" }, vim.fn.readfile(path))
	end)

	it("行数だけが違う場合も書く(サイズ足切りの取りこぼしが無い)", function()
		vim.fn.writefile({ "# Todo" }, path)
		local before = backdate(path)

		io_mod.read_lines(path)
		io_mod.write_lines(path, { "# Todo", "- [ ] a" })

		assert.are_not.equal(before, uv.fs_stat(path).mtime.sec)
		assert.are.same({ "# Todo", "- [ ] a" }, vim.fn.readfile(path))
	end)

	it("atomic_write も同じ内容なら書かない", function()
		vim.fn.writefile({ "x" }, path)
		local before = backdate(path)

		local ok = io_mod.atomic_write(path, "x\n")

		assert.is_true(ok, "書かない場合も成功として返すこと")
		assert.are.equal(before, uv.fs_stat(path).mtime.sec)
	end)

	it("atomic_write は内容が違えば書く", function()
		vim.fn.writefile({ "x" }, path)
		local before = backdate(path)

		assert.is_true(io_mod.atomic_write(path, "y\n"))

		assert.are_not.equal(before, uv.fs_stat(path).mtime.sec)
		assert.are.same({ "y" }, vim.fn.readfile(path))
	end)

	it("ファイルが存在しなければ書く", function()
		assert.are.equal(0, vim.fn.filereadable(path))

		io_mod.write_lines(path, { "# Todo" })

		assert.are.same({ "# Todo" }, vim.fn.readfile(path))
	end)

	-- 書かなかった場合も「バッファはディスクと同期済み」でなければならない。
	-- ここで modified が残ると、後続の :w や checktime が余計な書き込み・
	-- リロードを誘発する。
	it("書かなかった場合もバッファは同期済みになる", function()
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()
		io_mod.record_stamp(path)

		io_mod.write_lines(path, { "# Todo", "- [ ] a" })

		assert.is_false(vim.bo[buf].modified)
	end)
end)
