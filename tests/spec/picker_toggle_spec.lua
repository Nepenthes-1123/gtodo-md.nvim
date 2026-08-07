-- ピッカーからの完了トグルは task.lua を経由して行う。
--
-- 以前は `utils.is_todo_line`/`is_done_line`(無アンカーの部分文字列検索)で判定し、
-- `line:gsub("%[%s%]", "[x]")` で書き換えていた。Lua の gsub は件数を指定しなければ
-- 全件置換なので、本文中にチェックボックス記法を含むタスクをトグルすると本文まで
-- 無警告で書き換わっていた。この経路は io.write_lines でディスクへ確定するため、
-- 元の本文を戻す手段が実質無い。

local config = require("gtodo-md.config")
local picker = require("gtodo-md.integrations.picker")

describe("picker.toggle_task_file_line", function()
	local data_dir
	local saved_data_dir
	local path

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		config.setup({ data_dir = data_dir })
		path = data_dir .. "/todo.md"
	end)

	after_each(function()
		config.options.data_dir = saved_data_dir
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it("未完了を完了にし、completed_at を付与する", function()
		vim.fn.writefile({ "# Todo", "- [ ] 買い物" }, path)

		picker.toggle_task_file_line(path, 2)

		local line = vim.fn.readfile(path)[2]
		assert.is_truthy(line:find("- [x] 買い物", 1, true))
		assert.is_truthy(line:find("completed_at:" .. os.date("%Y-%m-%d"), 1, true))
	end)

	it("完了を未完了に戻し、completed_at を削除する", function()
		vim.fn.writefile({ "# Todo", "- [x] 買い物 completed_at:2026-08-01 id:a1b2c3" }, path)

		picker.toggle_task_file_line(path, 2)

		local line = vim.fn.readfile(path)[2]
		assert.is_truthy(line:find("- [ ] 買い物", 1, true))
		assert.is_nil(line:find("completed_at:", 1, true))
	end)

	-- 本丸の回帰: 本文中のチェックボックス記法を巻き込まないこと
	it("本文中の [ ] や [x] を書き換えない", function()
		local original = "- [ ] Review checklist template: contains [ ] and [x] placeholders"
		vim.fn.writefile({ "# Todo", original }, path)

		picker.toggle_task_file_line(path, 2)

		local line = vim.fn.readfile(path)[2]
		assert.is_truthy(
			line:find("contains [ ] and [x] placeholders", 1, true),
			"本文が書き換えられている: " .. line
		)
		assert.is_truthy(
			line:find("- [x] Review checklist", 1, true),
			"チェックボックスがトグルされていない"
		)
	end)

	it("完了→未完了の方向でも本文を書き換えない", function()
		local original = "- [x] Template with [ ] and [x] inside completed_at:2026-08-01 id:a1b2c3"
		vim.fn.writefile({ "# Todo", original }, path)

		picker.toggle_task_file_line(path, 2)

		local line = vim.fn.readfile(path)[2]
		assert.is_truthy(
			line:find("with [ ] and [x] inside", 1, true),
			"本文が書き換えられている: " .. line
		)
		assert.is_truthy(line:find("- [ ] Template", 1, true))
	end)

	it("タスク行でなければ何もしない", function()
		vim.fn.writefile({ "# Todo", "ただのテキスト行 [ ] を含む" }, path)

		picker.toggle_task_file_line(path, 2)

		assert.are.same({ "# Todo", "ただのテキスト行 [ ] を含む" }, vim.fn.readfile(path))
	end)

	it("存在しない行番号を渡しても壊れない", function()
		vim.fn.writefile({ "# Todo" }, path)

		picker.toggle_task_file_line(path, 99)

		assert.are.same({ "# Todo" }, vim.fn.readfile(path))
	end)
end)
