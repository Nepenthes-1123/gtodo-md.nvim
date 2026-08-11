-- io.move_file / io.find_buf の仕様を固定する先行テスト。
--
-- 実装は lua/gtodo-md/io.lua に以下の契約で追加する想定:
--   M.find_buf(path)      -> path(絶対パス)を vim.fn.fnamemodify(path, ":p") で正規化し、
--                             一致するロード済みバッファ番号を返す。無ければ nil。
--   M.move_file(src, dst) -> srcをdstへ移動(rename)する。成功時true。
--                             srcが存在しない場合は nil, エラー文字列 を返す(error()は投げない)。
--                             dstに既存ファイルがあっても確認なしに無条件で上書きする
--                             (衝突防止はこの関数の責務ではない)。

local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")

describe("io.move_file / io.find_buf", function()
	local data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	describe("move_file", function()
		it("成功時、srcの内容がそのままdstへ移動し、srcは消える", function()
			local src = data_dir .. "/foo.md"
			local dst = data_dir .. "/bar.md"
			vim.fn.writefile({ "- [ ] タスクA", "- [ ] タスクB" }, src)

			local ok, err = io_mod.move_file(src, dst)

			assert.is_true(ok)
			assert.is_nil(err)
			assert.are.same(0, vim.fn.filereadable(src))
			assert.are.same(1, vim.fn.filereadable(dst))
			assert.are.same({ "- [ ] タスクA", "- [ ] タスクB" }, vim.fn.readfile(dst))
		end)

		it(
			"srcが存在しない場合は nil, エラー文字列 を返し、dstは作られない(error()は投げない)",
			function()
				local src = data_dir .. "/does-not-exist.md"
				local dst = data_dir .. "/bar.md"

				local ok, err
				assert.has_no.errors(function()
					ok, err = io_mod.move_file(src, dst)
				end)

				assert.is_nil(ok)
				assert.is_string(err)
				assert.are.same(0, vim.fn.filereadable(dst))
			end
		)

		it(
			"dstに既存ファイルがある場合、確認なく無条件で上書きされる(衝突防止機能は無い)",
			function()
				local src = data_dir .. "/foo.md"
				local dst = data_dir .. "/bar.md"
				vim.fn.writefile({ "新しい内容" }, src)
				vim.fn.writefile({ "古い内容(上書きされるはず)" }, dst)

				local ok, err = io_mod.move_file(src, dst)

				assert.is_true(ok)
				assert.is_nil(err)
				assert.are.same(0, vim.fn.filereadable(src))
				assert.are.same({ "新しい内容" }, vim.fn.readfile(dst))
			end
		)

		it("data_dir配下の異なるサブディレクトリ間でも正しく動作する", function()
			local templates_dir = data_dir .. "/templates"
			local archive_dir = templates_dir .. "/archive"
			vim.fn.mkdir(templates_dir, "p")
			vim.fn.mkdir(archive_dir, "p")

			local src = templates_dir .. "/foo.md"
			local dst = archive_dir .. "/foo.md"
			vim.fn.writefile({ "- [ ] アーカイブ対象タスク" }, src)

			local ok, err = io_mod.move_file(src, dst)

			assert.is_true(ok)
			assert.is_nil(err)
			assert.are.same(0, vim.fn.filereadable(src))
			assert.are.same({ "- [ ] アーカイブ対象タスク" }, vim.fn.readfile(dst))
		end)
	end)

	describe("find_buf", function()
		it("対象パスにロード済みバッファが無ければ nil を返す", function()
			local path = data_dir .. "/no-buffer.md"
			vim.fn.writefile({ "- [ ] タスク" }, path)

			assert.is_nil(io_mod.find_buf(path))
		end)

		it("bufadd + bufload でバッファを作った後は、そのバッファ番号を返す", function()
			local path = data_dir .. "/with-buffer.md"
			vim.fn.writefile({ "- [ ] タスク" }, path)

			local bufnr = vim.fn.bufadd(path)
			vim.fn.bufload(bufnr)

			assert.are.same(bufnr, io_mod.find_buf(path))
		end)
	end)
end)
