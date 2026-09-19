-- 保存時バリデーションの結果を vim.diagnostic として出す。
--
-- 保存の中断(BufWritePre での error)は従来どおり残る。これは標準の保存処理を
-- 止める唯一の手段で、診断では代替できない。診断が引き受けるのは「何がどこで
-- 問題なのか」で、サイン・下線・]d でのジャンプ・vim.diagnostic.open_float が
-- そのまま効くようになる。
--
-- Neovim 0.12 の既定では virtual_text も virtual_lines も無効(サインと下線のみ)
-- のため、メッセージ本体は error 側にも残してある。ユーザーのグローバル設定に
-- 関わらずコマンドラインで理由が読めることを併せて確認する。

local config = require("gtodo-md.config")

local DIAG_NS = "gtodo-md/validate"

local function diagnostics_of(buf)
	return vim.diagnostic.get(buf, { namespace = vim.api.nvim_create_namespace(DIAG_NS) })
end

local function messages_of(buf)
	local out = {}
	for _, d in ipairs(diagnostics_of(buf)) do
		table.insert(out, d.message)
	end
	return out
end

local function contains(list, needle)
	for _, item in ipairs(list) do
		if item:find(needle, 1, true) then
			return true
		end
	end
	return false
end

describe("保存時バリデーションの診断", function()
	local data_dir, outside_dir

	-- 保存を試み、(成否, エラー文字列, バッファ番号)を返す。
	-- 診断を検査するためバッファは開いたままにする(after_each で片付ける)。
	local function open_and_write(path, lines)
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		local ok, err = pcall(function()
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("write!")
			end)
		end)
		return ok, tostring(err), buf
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		outside_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		vim.fn.mkdir(outside_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })
		require("gtodo-md").setup_autocmds()
	end)

	after_each(function()
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
		vim.fn.delete(outside_dir, "rf")
	end)

	-- 名前空間の設定で指定しなかったキーはグローバル設定へフォールバックする。
	-- そのため virtual_lines だけを有効にすると、ErrorLens 風に virtual_text を
	-- 有効にしている環境では同じ診断が行末と下の行へ二重に描画される。
	-- 実利用の設定がまさにこの形だったため、名前空間側で virtual_text を
	-- 明示的に無効にしている。
	it("グローバルで virtual_text が有効でも二重に描画しない", function()
		local saved = vim.diagnostic.config()
		vim.diagnostic.config({
			virtual_text = { enabled = true, spacing = 4, prefix = "■" },
			underline = true,
			signs = true,
		})
		require("gtodo-md").setup_autocmds() -- 名前空間の設定を張り直させる

		local _, _, buf = open_and_write(data_dir .. "/todo.md", { "# Todo", "", "## Today", "" })
		assert.is_true(#diagnostics_of(buf) > 0, "前提: 診断が出ていること")

		vim.api.nvim_set_current_buf(buf)
		vim.cmd("redraw")

		local kinds = {}
		for name, id in pairs(vim.api.nvim_get_namespaces()) do
			if name:find("gtodo%-md/validate%.diagnostic") then
				for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
					local d = mark[4]
					if d.virt_lines then
						kinds.virt_lines = true
					end
					if d.virt_text then
						kinds.virt_text = true
					end
				end
			end
		end

		vim.diagnostic.config(saved)

		assert.is_true(kinds.virt_lines, "virtual_lines が描画されていない")
		assert.is_nil(kinds.virt_text, "virtual_text と virtual_lines が二重に描画されている")
	end)

	it(
		"この名前空間に限って virtual_lines を有効にする(グローバル設定には触れない)",
		function()
			local ns = vim.api.nvim_create_namespace(DIAG_NS)
			assert.is_true(
				vim.diagnostic.config(nil, ns).virtual_lines,
				"名前空間限定の virtual_lines が無効"
			)
			assert.is_false(
				vim.diagnostic.config().virtual_lines,
				"グローバルの virtual_lines まで書き換えている"
			)
		end
	)

	describe("todo.md の必須セクション", function()
		it("不足しているセクションごとに診断を出し、保存は中断する", function()
			local ok, err, buf = open_and_write(data_dir .. "/todo.md", { "# Todo", "", "## Today", "" })

			assert.is_false(ok, "保存が中断されていない")
			local diags = diagnostics_of(buf)
			-- Next / Waiting / Someday の3つが不足している
			assert.are.same(
				3,
				#diags,
				"診断の件数が不足セクション数と一致しない: " .. vim.inspect(messages_of(buf))
			)
			for _, d in ipairs(diags) do
				assert.are.same(vim.diagnostic.severity.ERROR, d.severity)
				assert.are.same("gtodo-md", d.source)
			end
			assert.is_true(contains(messages_of(buf), "## Next"))
			-- 既定では診断がサインと下線しか出ないため、理由は error 側にも残す
			assert.is_true(
				err:find("必須セクション", 1, true) ~= nil,
				"理由がエラーに含まれていない: " .. err
			)
		end)

		-- **同じバッファを直して保存し直す**こと。別バッファで保存し直すと、
		-- そちらには元から診断が無いため「消している」ことを検証できない
		-- (クリア処理を削除しても通ってしまう)。
		it("同じバッファを修正して保存し直すと診断が消える", function()
			local path = data_dir .. "/todo.md"
			local ok, _, buf = open_and_write(path, { "# Todo", "", "## Today", "" })
			assert.is_false(ok, "前提: 1回目の保存が中断されること")
			assert.is_true(#diagnostics_of(buf) > 0, "前提: 診断が出ていること")

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
				"# Todo",
				"",
				"## Today",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			})
			local fixed_ok = pcall(function()
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("write!")
				end)
			end)

			assert.is_true(fixed_ok, "修正後も保存が中断されている")
			assert.are.same({}, diagnostics_of(buf), "修正後も古い診断が残っている")
		end)

		it("data_dir 外の同名ファイルには診断を出さない (#91)", function()
			local ok, _, buf = open_and_write(outside_dir .. "/todo.md", { "# 別プロジェクトのtodo" })
			assert.is_true(ok, "data_dir 外なのに保存が中断された")
			assert.are.same({}, diagnostics_of(buf))
		end)
	end)

	describe("inbox.md / done.md", function()
		it("必須ヘッダーの削除を診断として出す", function()
			local ok, err, buf = open_and_write(data_dir .. "/inbox.md", { "ヘッダーを消してしまった" })
			assert.is_false(ok)
			assert.is_true(contains(messages_of(buf), "# Inbox"), vim.inspect(messages_of(buf)))
			assert.is_true(err:find("必須ヘッダー", 1, true) ~= nil)
		end)

		it("履歴セクションの削除をセクションごとの診断として出す", function()
			local path = data_dir .. "/done.md"
			vim.fn.writefile({ "# Done", "", "## 2026-08", "", "## 2026-09", "" }, path)
			vim.cmd("edit " .. vim.fn.fnameescape(path)) -- BufReadPost で読み込み時のセクションを記録させる
			local buf = vim.api.nvim_get_current_buf()

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Done", "", "## 2026-09", "" })
			local ok = pcall(function()
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("write!")
				end)
			end)

			assert.is_false(ok, "履歴セクションを消したのに保存できてしまった")
			assert.is_true(contains(messages_of(buf), "## 2026-08"), vim.inspect(messages_of(buf)))
		end)
	end)

	describe("projects/*.md のフロントマター", function()
		local function write_project(tag, created, status_tag)
			local path = data_dir .. "/projects/" .. tag .. ".md"
			vim.fn.writefile({
				"---",
				"title: Demo",
				"tag: " .. (status_tag or tag),
				"created: " .. created,
				"due:",
				"status: active",
				"members: []",
				"---",
				"",
				"## Overview",
				"",
			}, path)
			return path
		end

		it("created の変更は created: の行に紐付ける", function()
			local path = write_project("alpha", "2025-01-01")
			vim.cmd("edit " .. vim.fn.fnameescape(path)) -- 読み込み時の created を記録させる
			local buf = vim.api.nvim_get_current_buf()

			vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "created: 2026-01-01" })
			local ok = pcall(function()
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("write!")
				end)
			end)

			assert.is_false(ok, "created を変更したのに保存できてしまった")
			local diags = diagnostics_of(buf)
			assert.are.same(1, #diags, vim.inspect(messages_of(buf)))
			-- created: は4行目 = 0-indexed で 3
			assert.are.same(3, diags[1].lnum, "created の診断が該当行に付いていない")
			assert.is_true(diags[1].message:find("created", 1, true) ~= nil)
		end)

		it("tag の不一致は tag: の行に紐付ける", function()
			local path = write_project("beta", "2025-01-01", "wrong-tag")
			local ok, _, buf = open_and_write(path, vim.fn.readfile(path))

			assert.is_false(ok, "tag が不一致なのに保存できてしまった")
			local diags = diagnostics_of(buf)
			assert.are.same(1, #diags, vim.inspect(messages_of(buf)))
			-- tag: は3行目 = 0-indexed で 2
			assert.are.same(2, diags[1].lnum, "tag の診断が該当行に付いていない")
		end)

		it("行を特定できない問題(必須項目の不足)は先頭行に付ける", function()
			local path = data_dir .. "/projects/gamma.md"
			local ok, _, buf = open_and_write(path, {
				"---",
				"title: Demo",
				"tag: gamma",
				"created: 2025-01-01",
				"---",
				"",
			})

			assert.is_false(ok)
			local diags = diagnostics_of(buf)
			assert.is_true(#diags > 0)
			assert.are.same(0, diags[1].lnum)
			assert.is_true(contains(messages_of(buf), "必須項目"), vim.inspect(messages_of(buf)))
		end)
	end)
end)
