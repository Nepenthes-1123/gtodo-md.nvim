-- #125: 並行更新(lost update)の検出。
--
-- read_lines はバッファがあればそちらを優先して読むため、他インスタンスが
-- その間にディスクを書き換えていると、write_lines の全行置換で相手の変更が
-- 黙って消える。書き込み直前に「読んだ時点から動いていないか」を照合し、
-- 動いていれば一切書かずに失敗させる。
--
-- これは検出であって防止ではない(stat から rename までの窓は残る)。

local io_mod = require("gtodo-md.io")

describe("io の並行更新検出", function()
	local path

	before_each(function()
		path = vim.fn.tempname() .. "_todo.md"
	end)

	after_each(function()
		vim.fn.delete(path)
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == path then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
	end)

	it(
		"読み取り後に外部が書き換えていたら書き込みを中止し、外部の内容が残る",
		function()
			vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
			-- ディスクから読む = スタンプが記録される
			local lines = io_mod.read_lines(path)
			assert.are.same({ "# Todo", "- [ ] a" }, lines)

			-- 他インスタンスによる書き換えを模倣(サイズを変える)
			vim.fn.writefile({ "# Todo", "- [ ] a", "- [ ] 他インスタンスが追加" }, path)

			local ok, err = pcall(io_mod.write_lines, path, { "# Todo", "- [ ] a", "- [ ] 自分の変更" })

			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("他のプロセスによって更新されています", 1, true))
			-- 外部の内容が上書きされずに残っていること
			assert.are.same({ "# Todo", "- [ ] a", "- [ ] 他インスタンスが追加" }, vim.fn.readfile(path))
		end
	)

	it("スタンプが無いパス(read を経ない書き込み)は照合しない", function()
		-- read_lines を呼ばずにいきなり書く
		vim.fn.writefile({ "# Todo" }, path)
		local ok = pcall(io_mod.write_lines, path, { "# Todo", "- [ ] x" })
		assert.is_true(ok)
		assert.are.same({ "# Todo", "- [ ] x" }, vim.fn.readfile(path))
	end)

	it("自分の書き込みを他インスタンスの更新と誤検出しない", function()
		vim.fn.writefile({ "# Todo" }, path)
		io_mod.read_lines(path)

		for i = 1, 3 do
			local ok, err = pcall(io_mod.write_lines, path, { "# Todo", "- [ ] " .. i })
			assert.is_true(ok, tostring(err))
		end
		assert.are.same({ "# Todo", "- [ ] 3" }, vim.fn.readfile(path))
	end)

	it("record_stamp を呼び直せば、外部更新後でも書けるようになる", function()
		vim.fn.writefile({ "# Todo" }, path)
		io_mod.read_lines(path)
		vim.fn.writefile({ "# Todo", "- [ ] 外部" }, path)

		assert.is_false(pcall(io_mod.write_lines, path, { "# Todo", "- [ ] 自分" }))

		-- :e 相当(BufReadPost で autocmds.lua が呼ぶのと同じ処理)
		io_mod.record_stamp(path)

		local ok, err = pcall(io_mod.write_lines, path, { "# Todo", "- [ ] 自分" })
		assert.is_true(ok, tostring(err))
	end)

	it(
		"バッファ優先で読んでもスタンプは更新されない(古いバッファでの上書きを検出できる)",
		function()
			vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
			io_mod.read_lines(path) -- ディスク読み = スタンプ記録

			-- バッファを開く(このスペックでは autocmd を張っていないためスタンプは動かない)
			vim.cmd("edit " .. vim.fn.fnameescape(path))

			-- 他インスタンスが追記
			vim.fn.writefile({ "# Todo", "- [ ] a", "- [ ] 他" }, path)

			-- バッファ優先で読む(古い内容が返る)
			local lines = io_mod.read_lines(path)
			assert.are.same({ "# Todo", "- [ ] a" }, lines)

			-- その内容で書き戻そうとすると検出される
			assert.is_false(pcall(io_mod.write_lines, path, lines))
			assert.are.same({ "# Todo", "- [ ] a", "- [ ] 他" }, vim.fn.readfile(path))
		end
	)
end)
