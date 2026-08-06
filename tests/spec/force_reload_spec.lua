-- 管理対象ファイルはディスクを正とする。
--
-- Vim は「ディスクが変わった、かつバッファに未保存編集がある」場合、'autoread' に
-- 関わらず W12 のプロンプト([O]K, (L)oad File:)で人間に聞く。未保存編集を勝手に
-- 捨てないための保護だが、同じ data_dir を複数インスタンスで共有する運用では
-- これが日常的に出るうえ、古いバッファを抱えたまま自動処理が走ると全行置換で
-- 他インスタンスの変更を潰す。FileChangedShell で v:fcs_choice = "reload" を
-- 指定して、プロンプトを出さずディスクの内容を採る。

local config = require("gtodo-md.config")
local uv = vim.uv or vim.loop

-- 他インスタンスによる書き換えを模倣する。mtime を明示的に進めるのは、
-- 同一秒内の書き換えだと Vim が変更を検知できずテストが空振りするため。
local function write_externally(path, lines)
	vim.fn.writefile(lines, path)
	local st = uv.fs_stat(path)
	uv.fs_utime(path, st.atime.sec + 10, st.mtime.sec + 10)
end

describe("管理対象バッファの強制リロード", function()
	local data_dir
	local saved_data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		config.setup({ data_dir = data_dir })
		require("gtodo-md").setup_autocmds()
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

	it("未保存編集があってもプロンプトを出さずディスクの内容へリロードする", function()
		local path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()

		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "- [ ] 打ちかけ" })
		assert.is_true(vim.bo[buf].modified, "前提: バッファが未保存であること")

		write_externally(path, { "# Todo", "- [ ] a", "- [ ] 他インスタンス" })
		vim.cmd("checktime " .. buf)

		assert.are.same(
			{ "# Todo", "- [ ] a", "- [ ] 他インスタンス" },
			vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		)
		assert.is_false(vim.bo[buf].modified)
	end)

	it("破棄された未保存編集は undo で復元できる", function()
		local path = data_dir .. "/inbox.md"
		vim.fn.writefile({ "# Inbox" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()

		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "- [ ] 打ちかけ" })
		write_externally(path, { "# Inbox", "- [ ] 他インスタンス" })
		vim.cmd("checktime " .. buf)
		assert.are.same({ "# Inbox", "- [ ] 他インスタンス" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

		vim.cmd("undo")

		assert.are.same({ "# Inbox", "- [ ] 打ちかけ" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)

	-- v:fcs_choice の "reload" は削除されたファイルには効かない。
	-- ファイル消失は黙って進めてよい事象ではないので既定のプロンプトへ委ねる。
	it("ファイルが削除された場合はリロードせず、バッファの内容を残す", function()
		local path = data_dir .. "/cancelled.md"
		vim.fn.writefile({ "# Cancelled", "- [ ] a" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()

		vim.fn.delete(path)
		pcall(vim.cmd, "checktime " .. buf)

		assert.are.same({ "# Cancelled", "- [ ] a" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)

	-- FileChangedShell は「autocmd が存在するだけで警告とプロンプトが抑制される」。
	-- 対象外のファイルまで黙って握り潰していないことを確認する。
	it("data_dir 外のファイルは強制リロードしない", function()
		local outside = vim.fn.tempname() .. "_other.md"
		vim.fn.writefile({ "A" }, outside)
		vim.cmd("edit " .. vim.fn.fnameescape(outside))
		local buf = vim.api.nvim_get_current_buf()

		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "USER" })
		write_externally(outside, { "A", "EXTERNAL" })
		pcall(vim.cmd, "checktime " .. buf)

		assert.are.same({ "A", "USER" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		assert.is_true(vim.bo[buf].modified, "対象外ファイルの未保存編集を破棄している")

		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		vim.fn.delete(outside)
	end)

	-- 「書く者を1つに絞る」方向では、他インスタンスのユーザー操作・:w・Neovim 以外の
	-- 書き手が素通りするため塞がらない。読む直前にディスクを取り込んで、
	-- 古いバッファを読むこと自体を無くす。
	it("with_write_lock は fn の実行前に管理対象バッファをリロードする", function()
		local path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))

		write_externally(path, { "# Todo", "- [ ] a", "- [ ] 他インスタンス" })

		local seen
		local acquired = require("gtodo-md.lock").with_write_lock(data_dir, function()
			-- read_lines はバッファ優先で読む。事前リロードが無ければ古い内容が返る。
			seen = require("gtodo-md.io").read_lines(path)
		end)

		assert.is_true(acquired)
		assert.are.same({ "# Todo", "- [ ] a", "- [ ] 他インスタンス" }, seen)
	end)

	-- Queue は eventignore で BufReadPost を止めて bufload するため、autocmds.lua が
	-- 行うスタンプ記録も一緒に落ちていた。スタンプが無いパスは write_lines 直前の
	-- 照合が素通りするので、並行更新検出が丸ごと効かない状態になっていた。
	it("Queue が quietly ロードしたバッファでも並行更新を検出できる", function()
		local path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)

		require("gtodo-md.ui.queue")._load_buf_quietly(path)

		-- 他インスタンスが追記
		vim.fn.writefile({ "# Todo", "- [ ] a", "- [ ] 他インスタンス" }, path)

		local io_mod = require("gtodo-md.io")
		-- バッファ優先で読むため古い内容が返る
		local stale = io_mod.read_lines(path)
		assert.are.same({ "# Todo", "- [ ] a" }, stale)

		local ok, err = pcall(io_mod.write_lines, path, stale)

		assert.is_false(ok, "スタンプが未記録で照合が素通りしている")
		assert.is_truthy(tostring(err):find("他のプロセスによって更新されています", 1, true))
		assert.are.same({ "# Todo", "- [ ] a", "- [ ] 他インスタンス" }, vim.fn.readfile(path))
	end)
end)
