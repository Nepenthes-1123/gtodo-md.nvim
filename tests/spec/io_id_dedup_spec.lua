-- コピー&ペーストで複製されたタスクが同じIDを持ち続けないことを確認する。
-- write_todo_file はファイル全体(全セクション・全サブセクション)を通して
-- ID重複を検知し、最初に登場した方以外を再発行する。

local io_mod = require("gtodo-md.io")

describe("io.write_todo_file の ID重複検知・再発行", function()
	local path

	before_each(function()
		path = vim.fn.tempname() .. "_dedup.md"
	end)

	after_each(function()
		vim.fn.delete(path)
	end)

	it("同一セクション内で同じIDを持つ2件のタスクは、後方だけ再発行される", function()
		local lines = {
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 元のタスク id:aaaaaa",
			"- [ ] コピーしたタスク id:aaaaaa",
		}
		local data = io_mod.parse_markdown(lines)
		io_mod.write_todo_file(path, data)

		local reread = io_mod.read_todo_file(path)
		local items = io_mod.get_section_items(reread.sections["Today"])

		assert.are.same(2, #items)
		assert.are.same("aaaaaa", items[1].task.id) -- 最初に登場した方は元のIDを保持
		assert.is_not_nil(items[2].task.id)
		assert.are_not.same("aaaaaa", items[2].task.id) -- 後方は再発行される
		assert.are_not.same(items[1].task.id, items[2].task.id) -- 結果として重複は解消される
	end)

	it("セクション・サブセクションをまたいだ重複も検知・再発行される", function()
		local lines = {
			"# Todo",
			"",
			"## Today",
			"",
			"### 仕事",
			"- [ ] 元のタスク id:bbbbbb",
			"",
			"## Next",
			"",
			"- [ ] コピーしたタスク id:bbbbbb",
		}
		local data = io_mod.parse_markdown(lines)
		io_mod.write_todo_file(path, data)

		local reread = io_mod.read_todo_file(path)
		local today_items = reread.sections["Today"].subsections[1].items
		local next_items = io_mod.get_section_items(reread.sections["Next"])

		assert.are.same("bbbbbb", today_items[1].task.id)
		assert.are_not.same("bbbbbb", next_items[1].task.id)
	end)

	it("重複が無ければIDは変化しない", function()
		local lines = {
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] タスクA id:cccccc",
			"- [ ] タスクB id:dddddd",
		}
		local data = io_mod.parse_markdown(lines)
		io_mod.write_todo_file(path, data)

		local reread = io_mod.read_todo_file(path)
		local items = io_mod.get_section_items(reread.sections["Today"])

		assert.are.same("cccccc", items[1].task.id)
		assert.are.same("dddddd", items[2].task.id)
	end)
end)
