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

	-- FileChangedShell は「autocmd が存在するだけで警告とプロンプトが抑制される」
	-- (:h FileChangedShell)。pattern = "*" で登録している以上、管理対象外のファイルには
	-- v:fcs_choice = "ask" を明示して既定の挙動へ戻さなければ、ユーザーの無関係な
	-- ファイルの外部変更が一切通知されなくなる。
	--
	-- 直前の「data_dir 外のファイルは強制リロードしない」は否定側(リロードされない)
	-- しか見ておらず、"ask" を書き忘れても v:fcs_choice が "" のまま素通りして通過する。
	-- そこで、プラグインの登録より後に観測用の autocmd を張り(autocmd は登録順に
	-- 実行される)、コールバックが実際に置いた値そのものを検証する。
	--
	-- 前提: FileChangedShell は "Not used when 'autoread' is set and the buffer was
	-- not changed"(:h FileChangedShell)。'autoread' は既定で on のため、バッファを
	-- 未保存(dirty)にしておかないと autoread による無言リロードになり発火しない。
	it('data_dir 外のファイルには v:fcs_choice = "ask" を明示して既定の挙動へ戻す', function()
		local observed = {}
		local probe = vim.api.nvim_create_augroup("GtodoMdFcsProbe", { clear = true })
		vim.api.nvim_create_autocmd("FileChangedShell", {
			group = probe,
			pattern = "*",
			callback = function(args)
				observed[vim.api.nvim_buf_get_name(args.buf)] = vim.v.fcs_choice
			end,
		})

		local managed = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "- [ ] a" }, managed)
		vim.cmd("edit " .. vim.fn.fnameescape(managed))
		local managed_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(managed_buf, -1, -1, false, { "- [ ] 打ちかけ" })
		write_externally(managed, { "# Todo", "- [ ] a", "- [ ] 他インスタンス" })
		pcall(vim.cmd, "checktime " .. managed_buf)

		local outside = vim.fn.tempname() .. "_other.md"
		vim.fn.writefile({ "A" }, outside)
		vim.cmd("edit " .. vim.fn.fnameescape(outside))
		local outside_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(outside_buf, -1, -1, false, { "USER" })
		write_externally(outside, { "A", "EXTERNAL" })
		pcall(vim.cmd, "checktime " .. outside_buf)

		-- 削除は "reload" が効かない(:h v:fcs_choice)うえ、黙って進めてよい事象でもない。
		-- 直後の「ファイルが削除された場合はリロードせず…」は、"reload" が削除済み
		-- ファイルに効かないという別の理由でも通ってしまうため、ここで v:fcs_choice の
		-- 値そのものを確認する。
		local deleted = data_dir .. "/cancelled.md"
		vim.fn.writefile({ "# Cancelled", "- [ ] a" }, deleted)
		vim.cmd("edit " .. vim.fn.fnameescape(deleted))
		local deleted_buf = vim.api.nvim_get_current_buf()
		vim.fn.delete(deleted)
		pcall(vim.cmd, "checktime " .. deleted_buf)

		vim.api.nvim_del_augroup_by_id(probe)

		assert.are.same(
			"reload",
			observed[vim.api.nvim_buf_get_name(managed_buf)],
			"管理対象に reload を指定していない"
		)
		assert.are.same(
			"ask",
			observed[vim.api.nvim_buf_get_name(outside_buf)],
			"管理対象外に ask を明示しておらず、外部変更が黙って握り潰される"
		)
		assert.are.same(
			"ask",
			observed[vim.api.nvim_buf_get_name(deleted_buf)],
			"管理対象でもファイル削除時は ask を明示する必要がある"
		)

		pcall(vim.api.nvim_buf_delete, outside_buf, { force = true })
		vim.fn.delete(outside)
	end)

	-- 「書く者を1つに絞る」方向では、他インスタンスのユーザー操作・:w・Neovim 以外の
	-- 書き手が素通りするため塞がらない。読む直前にディスクを取り込んで、
	-- 古いバッファを読むこと自体を無くす。
	it("with_automation_lock は fn の実行前に管理対象バッファをリロードする", function()
		local path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))

		write_externally(path, { "# Todo", "- [ ] a", "- [ ] 他インスタンス" })

		local seen
		local acquired = require("gtodo-md.lock").with_automation_lock(data_dir, function()
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

	-- スタンプを記録してよいのは bufload の直後だけ。既にロード済みのバッファは
	-- いつの時点のディスクを写したものか分からないため、そこで今のディスクを刻印すると
	-- 「古いバッファ＝新しいディスク」と誤って宣言し、検出が恒久的に素通りする。
	it("Queue は既ロード済みバッファのスタンプを塗り替えない", function()
		local path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "- [ ] a" }, path)

		-- 通常経路で開く(BufReadPost で autocmds.lua がスタンプを記録する)
		vim.cmd("edit " .. vim.fn.fnameescape(path))

		-- 他インスタンスが追記。この時点でスタンプは古くなっている
		vim.fn.writefile({ "# Todo", "- [ ] a", "- [ ] 他インスタンス" }, path)

		-- Queue を開く。既ロード済みなので bufload は走らない
		require("gtodo-md.ui.queue")._load_buf_quietly(path)

		local io_mod = require("gtodo-md.io")
		local stale = io_mod.read_lines(path)
		local ok, err = pcall(io_mod.write_lines, path, stale)

		assert.is_false(ok, "既ロード済み経路でスタンプを塗り替え、検出を無効化している")
		assert.is_truthy(tostring(err):find("他のプロセスによって更新されています", 1, true))
		assert.are.same({ "# Todo", "- [ ] a", "- [ ] 他インスタンス" }, vim.fn.readfile(path))
	end)
end)
