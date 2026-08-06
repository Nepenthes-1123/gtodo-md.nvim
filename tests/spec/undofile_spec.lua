-- #125 (E828) 回帰テスト: 管理対象バッファでは永続 undo を無効化する。
--
-- checktime は外部変更を検知してバッファをリロードした直後、'undofile' が
-- 有効なら u_write_undo() を呼ぶ。u_write_undo() は既存の undo ファイルを
-- 削除してから O_EXCL で作り直すため、同じファイルを開いた複数インスタンスが
-- 同一の undo ファイルパスを奪い合い、負けた側が E828 になる。
-- undo ファイルはプロセス間でロックされない。

local config = require("gtodo-md.config")

describe("管理対象バッファの undofile", function()
	local data_dir
	local saved_data_dir
	local saved_undofile

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		saved_undofile = vim.go.undofile
		config.setup({ data_dir = data_dir })
		-- ユーザーがグローバルに undofile を有効にしている状況を再現する
		vim.go.undofile = true
		require("gtodo-md").setup_autocmds()
	end)

	after_each(function()
		vim.go.undofile = saved_undofile
		config.options.data_dir = saved_data_dir
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	it("data_dir 配下のファイルを開くと undofile が無効になる", function()
		local todo_path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "" }, todo_path)

		vim.cmd("edit " .. vim.fn.fnameescape(todo_path))
		local buf = vim.api.nvim_get_current_buf()

		assert.is_false(vim.bo[buf].undofile)
	end)

	it("data_dir 外のファイルの undofile は変更しない", function()
		local other = vim.fn.tempname() .. "_other.md"
		vim.fn.writefile({ "# Other" }, other)

		vim.cmd("edit " .. vim.fn.fnameescape(other))
		local buf = vim.api.nvim_get_current_buf()

		assert.is_true(vim.bo[buf].undofile, "無関係なファイルの undofile まで落としている")

		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		vim.fn.delete(other)
	end)

	it("reload_managed_bufs も保険として undofile を落とす", function()
		local todo_path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "" }, todo_path)

		local buf = vim.fn.bufadd(todo_path)
		vim.fn.bufload(buf)
		-- autocmd を経由せずに開かれた状態を模倣する
		vim.bo[buf].undofile = true

		require("gtodo-md.daily").reload_managed_bufs()

		assert.is_false(vim.bo[buf].undofile)
	end)

	it("checktime によるリロードが例外を投げても呼び出し元を巻き込まない", function()
		local todo_path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "" }, todo_path)
		local buf = vim.fn.bufadd(todo_path)
		vim.fn.bufload(buf)

		-- reload_managed_bufs 自体が pcall で隔離されていること
		local ok = pcall(require("gtodo-md.daily").reload_managed_bufs)
		assert.is_true(ok)
	end)

	-- #125 追従: 対象判定がファイル名の末尾一致だったため、cancelled.md と
	-- projects/*.md が reload_managed_bufs から漏れていた。
	it("reload_managed_bufs は cancelled.md も対象にする", function()
		local path = data_dir .. "/cancelled.md"
		vim.fn.writefile({ "# Cancelled", "" }, path)
		local buf = vim.fn.bufadd(path)
		vim.fn.bufload(buf)
		vim.bo[buf].undofile = true
		vim.bo[buf].autoread = false

		require("gtodo-md.daily").reload_managed_bufs()

		assert.is_false(vim.bo[buf].undofile, "cancelled.md が対象から漏れている")
		assert.is_true(vim.bo[buf].autoread)
	end)

	it("reload_managed_bufs は projects/*.md も対象にする", function()
		local path = data_dir .. "/projects/foo.md"
		vim.fn.writefile({ "---", "tag: foo", "---" }, path)
		local buf = vim.fn.bufadd(path)
		vim.fn.bufload(buf)
		vim.bo[buf].undofile = true
		vim.bo[buf].autoread = false

		require("gtodo-md.daily").reload_managed_bufs()

		assert.is_false(vim.bo[buf].undofile, "projects/*.md が対象から漏れている")
		assert.is_true(vim.bo[buf].autoread)
	end)

	it("reload_managed_bufs は data_dir 外の同名ファイルを対象にしない", function()
		local outside = vim.fn.tempname() .. "_todo.md"
		vim.fn.writefile({ "# Todo" }, outside)
		local buf = vim.fn.bufadd(outside)
		vim.fn.bufload(buf)
		vim.bo[buf].undofile = true

		require("gtodo-md.daily").reload_managed_bufs()

		assert.is_true(vim.bo[buf].undofile, "data_dir 外のファイルまで対象にしている")

		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		vim.fn.delete(outside)
	end)

	-- #125 追従: Queue は eventignore で BufReadPost/BufEnter を止めて bufload
	-- するため、autocmds.lua の設定が一切かからないバッファを作っていた。
	it("Queue が quietly ロードしたバッファにも undofile=false が入る", function()
		local todo_path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "", "## Today", "" }, todo_path)

		local buf = require("gtodo-md.ui.queue")._load_buf_quietly(todo_path)

		assert.is_false(vim.bo[buf].undofile, "eventignore 経路で undofile が残っている")
		assert.is_true(vim.bo[buf].autoread)
	end)

	it("Queue は data_dir 外のファイルの undofile を変更しない", function()
		local outside = vim.fn.tempname() .. "_other.md"
		vim.fn.writefile({ "x" }, outside)

		local buf = require("gtodo-md.ui.queue")._load_buf_quietly(outside)

		assert.is_true(vim.bo[buf].undofile, "管理対象外のファイルまで変更している")

		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		vim.fn.delete(outside)
	end)

	-- #125 追従: write_lines が自分で撃つ checktime も、割り込みが起きていれば
	-- リロードを誘発しうる。その間だけ undofile を落とし、必ず元へ戻す。
	it("write_lines は checktime の前後で undofile を退避・復元する", function()
		local outside = vim.fn.tempname() .. "_plain.md"
		vim.fn.writefile({ "a" }, outside)
		vim.cmd("edit " .. vim.fn.fnameescape(outside))
		local buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].undofile = true

		require("gtodo-md.io").write_lines(outside, { "a", "b" })

		assert.is_true(vim.bo[buf].undofile, "管理対象外バッファの undofile を戻していない")
		assert.are.same({ "a", "b" }, vim.fn.readfile(outside))

		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		vim.fn.delete(outside)
	end)
end)
