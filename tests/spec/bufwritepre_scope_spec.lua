-- #91 回帰テスト: BufWritePre バリデーションが data_dir 外の同名ファイルにも
-- 発動してしまう不具合。autocmdのpatternはファイル名の末尾一致のみのため、
-- ユーザーが全く別の場所で "todo.md"/"inbox.md" 等のファイルを保存しようと
-- すると、gtodo-md固有のバリデーションでブロックされてしまっていた。

local config = require("gtodo-md.config")

describe("BufWritePreバリデーションのスコープ (#91)", function()
	local data_dir, outside_dir

	local function try_write(path, lines)
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		local ok, err = pcall(function()
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("write!")
			end)
		end)

		vim.api.nvim_buf_delete(buf, { force = true })
		return ok, err
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		outside_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		vim.fn.mkdir(outside_dir, "p")
		config.setup({ data_dir = data_dir })
		require("gtodo-md").setup_autocmds()
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
		vim.fn.delete(outside_dir, "rf")
	end)

	it("data_dir外のtodo.mdは必須セクションが欠けていても保存できる", function()
		local ok = try_write(outside_dir .. "/todo.md", { "# 別プロジェクトのtodo" })
		assert.is_true(ok, "data_dir外のtodo.mdなのに保存がブロックされた")
	end)

	it(
		"data_dir内のtodo.mdは引き続き必須セクションが無いと保存を中断する(回帰確認)",
		function()
			local ok = try_write(data_dir .. "/todo.md", { "# Todo" })
			assert.is_false(ok, "data_dir内のtodo.mdなのにバリデーションが働いていない")
		end
	)

	it("data_dir外のinbox.mdは必須ヘッダーが欠けていても保存できる", function()
		local ok = try_write(outside_dir .. "/inbox.md", { "no header here" })
		assert.is_true(ok, "data_dir外のinbox.mdなのに保存がブロックされた")
	end)

	it(
		"data_dir内のinbox.mdは引き続き必須ヘッダーが無いと保存を中断する(回帰確認)",
		function()
			local ok = try_write(data_dir .. "/inbox.md", { "no header here" })
			assert.is_false(ok, "data_dir内のinbox.mdなのにバリデーションが働いていない")
		end
	)

	it("data_dir外のprojects/*.mdはフロントマターが欠けていても保存できる", function()
		vim.fn.mkdir(outside_dir .. "/projects", "p")
		local ok = try_write(outside_dir .. "/projects/foo.md", { "no frontmatter here" })
		assert.is_true(ok, "data_dir外のprojects/*.mdなのに保存がブロックされた")
	end)
end)
