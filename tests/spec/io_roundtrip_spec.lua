local io_mod = require("gtodo-md.io")

-- write_todo_file はタスク行に id:XXXXXX タグをランダム発行して付与するため、
-- 厳密一致比較ではこれを除いた行で比較する。
local function strip_ids(lines)
	local result = {}
	for i, line in ipairs(lines) do
		result[i] = (line:gsub("%s+id:%x+%s*$", ""))
	end
	return result
end

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
		-- write_todo_file は末尾の空行を取り除いて書き出すため、通常ここは
		-- 素通りする。将来また末尾へ空行が混入した場合に備えた保険として、
		-- written_lines の末尾が空文字列なら除去して比較する
		if written_lines[#written_lines] == "" then
			table.remove(written_lines)
		end

		assert.are.same(original_lines, strip_ids(written_lines))
	end)

	-- 手動編集等でヘッダー部分(最初の## 見出しより前)に空行が連続していると、
	-- data.header はその行をそのままechoするだけで空行をフィルタしないため
	-- (セクション内のitemsとは異なり)、書き戻しても連続空行がそのまま残り
	-- markdownlintのMD012(連続する空行)に引っかかっていた。
	it("ヘッダー部分の連続する空行は書き出し時に1行へ圧縮される(MD012対策)", function()
		local original_lines = {
			"# Todo",
			"",
			"",
			"## Today",
			"",
			"- [ ] タスクA",
			"",
			"",
			"## Next",
			"",
		}

		local data = io_mod.parse_markdown(original_lines)
		local tmpfile = vim.fn.tempname() .. ".md"
		io_mod.write_todo_file(tmpfile, data)
		local written_lines = strip_ids(vim.fn.readfile(tmpfile))
		vim.fn.delete(tmpfile)

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
