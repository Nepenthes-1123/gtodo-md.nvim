-- highlight.setup() 実行時点で既に存在するバッファ/ウィンドウへ、conceal 設定と
-- ハイライトが遡って適用される(バックフィル)ことを検証する。
-- lazy.nvim の ft/cmd/keys/event 等で setup() がバッファ表示より後に走る構成では、
-- BufWinEnter も BufReadPost も既に発火し終えているため、autocmd の登録だけでは
-- 既存のバッファ/ウィンドウに何も適用されなかった。

local highlight_mod = require("gtodo-md.highlight")
local config = require("gtodo-md.config")

local ns = vim.api.nvim_create_namespace("gtodo_highlights")

local TASK_LINE = "- [ ] バックフィル確認 due:2025-01-01 id:a1b2c3"

-- update_highlights は vim.schedule で実処理を遅延させているため、
-- イベントループを一度回して完了を待つ
local function wait_for_scheduled()
	vim.wait(100, function()
		return false
	end)
end

-- conceal extmark が覆っているテキストを返す(無ければ nil)
local function concealed_text(bufnr)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		local details = mark[4]
		if details.conceal == "" then
			local line = vim.api.nvim_buf_get_lines(bufnr, mark[2], mark[2] + 1, false)[1]
			return line:sub(mark[3] + 1, details.end_col)
		end
	end
	return nil
end

local function setup_data_dir()
	local data_dir = vim.fn.tempname()
	vim.fn.mkdir(data_dir, "p")
	local path = data_dir .. "/todo.md"
	vim.fn.writefile({ "# Todo", "", "## Today", "", TASK_LINE }, path)
	config.setup({ data_dir = data_dir })
	return data_dir, path
end

local function cleanup(data_dir, bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end
	vim.fn.delete(data_dir, "rf")
end

describe("highlight.setup: 既存バッファ/ウィンドウへのバックフィル", function()
	it("先にファイルを開いてから setup() を呼んでも適用される", function()
		local data_dir, path = setup_data_dir()

		-- 「setup() 前に開く」状況を再現するため、先行するテストや他モジュールが
		-- 登録した autocmd を明示的に取り除いておく
		pcall(vim.api.nvim_del_augroup_by_name, "GTodoConceal")

		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
		vim.api.nvim_set_option_value("concealcursor", "nc", { win = win })

		-- 前提: この時点では何も適用されていない
		assert.are.same(0, vim.api.nvim_get_option_value("conceallevel", { win = win }))
		assert.are.same(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))

		highlight_mod.setup()

		assert.are.same(2, vim.api.nvim_get_option_value("conceallevel", { win = win }))
		assert.are.same("", vim.api.nvim_get_option_value("concealcursor", { win = win }))

		wait_for_scheduled()
		assert.are.same(" id:a1b2c3", concealed_text(buf))

		cleanup(data_dir, buf)
	end)

	it("setup() を先に呼んでからファイルを開く従来の順序でも動作する", function()
		local data_dir, path = setup_data_dir()

		highlight_mod.setup()

		-- setup() 直後は対象バッファが存在しない状態から始める
		vim.cmd("enew")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
		vim.api.nvim_set_option_value("concealcursor", "nc", { win = win })

		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()

		-- conceallevel/concealcursor は BufWinEnter の autocmd が設定する
		assert.are.same(2, vim.api.nvim_get_option_value("conceallevel", { win = win }))
		assert.are.same("", vim.api.nvim_get_option_value("concealcursor", { win = win }))

		-- extmark の付与は autocmds.lua の BufReadPost が attach を呼ぶ経路。
		-- ここでは autocmds.setup() の副作用(自動ソート等)を避けるため直接呼ぶ。
		highlight_mod.attach(buf)
		wait_for_scheduled()
		assert.are.same(" id:a1b2c3", concealed_text(buf))

		cleanup(data_dir, buf)
	end)

	it("data_dir 配下でないバッファはバックフィルの対象外", function()
		local data_dir = setup_data_dir()

		local other_dir = vim.fn.tempname()
		vim.fn.mkdir(other_dir, "p")
		local other_path = other_dir .. "/todo.md"
		vim.fn.writefile({ TASK_LINE }, other_path)

		pcall(vim.api.nvim_del_augroup_by_name, "GTodoConceal")
		vim.cmd("edit " .. vim.fn.fnameescape(other_path))
		local buf = vim.api.nvim_get_current_buf()
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_option_value("conceallevel", 0, { win = win })

		highlight_mod.setup()
		wait_for_scheduled()

		assert.are.same(0, vim.api.nvim_get_option_value("conceallevel", { win = win }))
		assert.are.same(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))

		cleanup(other_dir, buf)
		vim.fn.delete(data_dir, "rf")
	end)
end)
