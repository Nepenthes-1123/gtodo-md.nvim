local io_mod = require("gtodo-md.io")


describe("io.lua parse_markdown and write_todo_file roundtrip", function()
	it("parse_markdown と write_todo_file で内容が完全に一致する", function()
		local original_lines = {
			"# Todo",
			"",
			"## Today",
			"",
			"### 仕事",
			"",
			"- [ ] (A) タスクA due:2025-01-01",
			"- [ ] タスクB @office",
			"",
			"### プライベート",
			"",
			"- [x] 完了タスク +home",
			"",
			"## Next",
			"",
			"- [ ] 次のタスク",
		}

		-- 1. パースする
		local data = io_mod.parse_markdown(original_lines)

		-- 2. 一時ファイルに書き出す
		local tmpfile = vim.fn.tempname() .. ".md"
		io_mod.write_todo_file(tmpfile, data)

		-- 3. 書き出された内容を読み込む
		local written_lines = vim.fn.readfile(tmpfile)
		vim.fn.delete(tmpfile)

		-- 空行の扱いやファイル末尾の改行により、完全に一致するかをテスト
		-- write_todo_file は末尾に必ず空行を追加するため、
		-- written_lines の末尾が空文字列なら除去して比較する
		if written_lines[#written_lines] == "" then
			table.remove(written_lines)
		end

		assert.are.same(original_lines, written_lines)
	end)
end)
