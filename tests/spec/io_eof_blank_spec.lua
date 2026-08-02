local io_mod = require("gtodo-md.io")

-- write_todo_file は以前、末尾の空行を全て取り除いた後に必ず空文字列の行を
-- 1つ足していた。write_lines_to_disk は各行の後ろに改行を付けて書き出すため、
-- 最終行の改行と合わせてファイル末尾が "\n\n" になり、:w のたびに
-- 末尾の空行が1行増える(markdownlint MD012)不具合になっていた。
describe("io.lua write_todo_file のファイル末尾処理", function()
	-- 一時ファイルへ書き出し、行リストと生のバイト列を返す
	local function write_and_read(lines)
		local data = io_mod.parse_markdown(lines)
		local tmpfile = vim.fn.tempname() .. ".md"
		io_mod.write_todo_file(tmpfile, data)

		local written_lines = vim.fn.readfile(tmpfile)
		local f = assert(io.open(tmpfile, "rb"))
		local raw = f:read("*a")
		f:close()
		vim.fn.delete(tmpfile)

		return written_lines, raw
	end

	it("書き出し結果の末尾に空行が含まれない", function()
		local written_lines = write_and_read({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] タスクA",
			"",
			"## Someday",
		})

		assert.is_true(#written_lines > 0)
		assert.are_not.equal("", written_lines[#written_lines])
	end)

	it("ファイルは改行で終わり、最終行の内容は失われない", function()
		local written_lines, raw = write_and_read({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] タスクA",
			"",
			"## Someday",
		})

		assert.are.equal("## Someday", written_lines[#written_lines])
		-- 末尾は改行1つで終わる(改行が2つ続く = 空行が残っている、ではない)
		assert.is_true(
			raw:sub(-1) == "\n",
			"ファイルが改行で終わっていない: " .. vim.inspect(raw:sub(-10))
		)
		assert.is_nil(
			raw:match("\n%s*\n$"),
			"ファイル末尾に空行が残っている: " .. vim.inspect(raw:sub(-10))
		)
	end)

	it("元データの末尾に空行が複数あっても書き出し後の末尾空行は0行になる", function()
		local written_lines, raw = write_and_read({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] タスクA",
			"",
			"## Someday",
			"",
			"",
			"",
		})

		assert.are.equal("## Someday", written_lines[#written_lines])
		assert.is_nil(
			raw:match("\n%s*\n$"),
			"ファイル末尾に空行が残っている: " .. vim.inspect(raw:sub(-10))
		)
	end)

	-- 同じ内容を繰り返し書き戻しても末尾が変化しない(:w の反復で空行が
	-- 積み増されないこと)を、パース→書き出しのラウンドトリップで確認する。
	it("パースと書き出しを繰り返しても末尾の行数が増えない", function()
		local lines = {
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] タスクA",
			"",
			"## Someday",
		}

		local first = write_and_read(lines)
		local second = write_and_read(first)
		local third = write_and_read(second)

		assert.are.equal(#first, #second)
		assert.are.equal(#second, #third)
		assert.are_not.equal("", third[#third])
	end)

	-- #108 の回帰防止: 末尾処理の変更で中間の連続空行の圧縮が壊れていないこと
	it("中間の連続する空行は引き続き1行へ圧縮される(#108 の回帰防止)", function()
		local written_lines = write_and_read({
			"# Todo",
			"",
			"",
			"",
			"## Today",
			"",
			"- [ ] タスクA",
			"",
			"",
			"## Next",
			"",
			"- [ ] タスクB",
		})

		for i, line in ipairs(written_lines) do
			if vim.trim(line) == "" and i > 1 then
				assert.is_true(
					vim.trim(written_lines[i - 1]) ~= "",
					"連続する空行が圧縮されていない: " .. vim.inspect(written_lines)
				)
			end
		end
	end)
end)
