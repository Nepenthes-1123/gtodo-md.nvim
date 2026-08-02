local M = {}
local ns = vim.api.nvim_create_namespace("gtodo_highlights")
local utils = require("gtodo-md.utils")

local pending_updates = {}

local hl_groups = {
	project = "GTodoProject", -- +Project
	context = "GTodoContext", -- @context
	date_normal = "GTodoDate", -- due:YYYY-MM-DD
	date_warn = "GTodoDateWarn", -- due:today
	date_error = "GTodoDateError", -- overdue
	priority_a = "GTodoPriorityA", -- (A)
	priority_b = "GTodoPriorityB", -- (B)
	priority_c = "GTodoPriorityC", -- (C)
}

-- setup() 時点で既に存在するバッファ/ウィンドウへ、conceal 設定とハイライトを
-- 遡って適用する(バックフィル)。
-- autocmd は「これから発火するイベント」にしか効かないため、lazy.nvim の
-- ft/cmd/keys/event 等で setup() がバッファ表示より後に走る構成では、
-- BufWinEnter(conceallevel/concealcursor)も autocmds.lua の BufReadPost(attach)も
-- 既に発火し終えており、開いたままのバッファ/ウィンドウには何も適用されない。
local function backfill_existing()
	local data_dir = require("gtodo-md.config").get("data_dir")
	if not data_dir or data_dir == "" then
		return
	end

	-- 対象判定は BufWinEnter/BufReadPost のコールバックと同一のロジックを使う
	-- (pattern = "*.md" によるファイル名の絞り込みを含む)
	local is_target = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
			local bufname = vim.api.nvim_buf_get_name(bufnr)
			if bufname:match("%.md$") and bufname:find(data_dir, 1, true) then
				is_target[bufnr] = true
				-- attach は augroup(clear = true) を使うため冪等。
				-- 既に attach 済みのバッファに再度呼んでも二重登録にはならない。
				M.attach(bufnr)
			end
		end
	end

	-- conceallevel/concealcursor はウィンドウローカルのため、カレントウィンドウを
	-- 指す vim.wo ではなく対象ウィンドウを明示して設定する
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) and is_target[vim.api.nvim_win_get_buf(win)] then
			vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
			vim.api.nvim_set_option_value("concealcursor", "", { win = win })
		end
	end
end

function M.setup()
	-- デフォルトのハイライトグループを定義 (ユーザーが上書き可能)
	vim.api.nvim_set_hl(0, "GTodoProject", { link = "Type", default = true })
	vim.api.nvim_set_hl(0, "GTodoContext", { link = "Identifier", default = true })
	vim.api.nvim_set_hl(0, "GTodoDate", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "GTodoDateWarn", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "GTodoDateError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "GTodoPriorityA", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "GTodoPriorityB", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "GTodoPriorityC", { link = "DiagnosticInfo", default = true })
	vim.api.nvim_set_hl(0, "GTodoWait", { link = "Special", default = true })

	-- wait: タグは静的な syntax match で処理する
	vim.cmd([[
    augroup GTodoWaitSyntax
      autocmd!
      autocmd Syntax markdown,gtodo syntax match GTodoWait /\(^\|\s\+\)wait:[^[:space:]　。、.,()（）]\+/ containedin=ALL
    augroup END
  ]])

	-- id: タグをconcealで隠すため、gtodo管理下のバッファを表示するウィンドウに
	-- conceallevel/concealcursor を設定する。concealcursor を空にすることで、
	-- カーソルがその行にある間は自動的に見える状態へ戻り、通常通り編集できる。
	-- BufWinEnter を使うことで、既存バッファを新しいウィンドウ(:sp等)で
	-- 開いた場合にも確実に設定される。
	local conceal_group = vim.api.nvim_create_augroup("GTodoConceal", { clear = true })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = conceal_group,
		pattern = "*.md",
		callback = function(args)
			local bufname = vim.api.nvim_buf_get_name(args.buf)
			local data_dir = require("gtodo-md.config").get("data_dir")
			if data_dir and data_dir ~= "" and bufname:find(data_dir, 1, true) then
				vim.wo.conceallevel = 2
				vim.wo.concealcursor = ""
			end
		end,
	})

	-- 上記 autocmd は setup() 以降に開かれるバッファ/ウィンドウにしか効かないため、
	-- 既に存在するものへ遡って適用する
	backfill_existing()
end

function M.update_highlights(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if pending_updates[bufnr] then
		return
	end
	pending_updates[bufnr] = true

	vim.schedule(function()
		pending_updates[bufnr] = false
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		local ok, err = pcall(function()
			-- 既存のハイライトをクリア
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local today_time = utils.date_to_time(os.date("%Y-%m-%d"))

			for i, line in ipairs(lines) do
				if utils.is_todo_line(line) or utils.is_done_line(line) then
					-- 1. Project tag (+Project)
					for s, tag in line:gmatch("()(%+[%w%-_/%.]+)") do
						vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, s - 1, {
							end_col = s - 1 + #tag,
							hl_group = hl_groups.project,
							ephemeral = false,
						})
					end

					-- 2. Context (@context)
					for s, ctx in line:gmatch("()(@[%w%-_/%.]+)") do
						vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, s - 1, {
							end_col = s - 1 + #ctx,
							hl_group = hl_groups.context,
							ephemeral = false,
						})
					end

					-- 3. Priority ((A), (B), (C))
					local p_s, p_c = line:match("()(%([A-Z]%))")
					if p_s then
						local p_char = p_c:sub(2, 2)
						local hl = hl_groups.priority_c
						if p_char == "A" then
							hl = hl_groups.priority_a
						elseif p_char == "B" then
							hl = hl_groups.priority_b
						end
						vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, p_s - 1, {
							end_col = p_s - 1 + 3,
							hl_group = hl,
							ephemeral = false,
						})
					end

					-- 4. Due dates (due:YYYY-MM-DD)
					local d_s, d_str = line:match("()(due:%d%d%d%d%-%d%d%-%d%d)")
					if d_s then
						local date_val = d_str:sub(5)
						local due_time = utils.date_to_time(date_val)
						local hl = hl_groups.date_normal
						local vtext = ""

						if due_time then
							local diff = math.floor((due_time - today_time) / 86400)
							local lang = type(vim.v.lang) == "string" and vim.v.lang or os.getenv("LANG") or ""
							local time_lang = os.setlocale(nil, "time") or ""
							local is_ja = string.match(lang, "^ja")

							if string.match(time_lang, "^en") then
								is_ja = false
							elseif string.match(time_lang, "^ja") then
								is_ja = true
							end

							if diff < 0 then
								hl = hl_groups.date_error
								vtext = is_ja and string.format(" (%d日超過)", -diff)
									or string.format(" (%d overdue)", -diff)
							elseif diff == 0 then
								hl = hl_groups.date_warn
								vtext = is_ja and " (今日)" or " (Today)"
							elseif diff == 1 then
								hl = hl_groups.date_normal
								vtext = is_ja and " (明日)" or " (Tomorrow)"
							else
								vtext = is_ja and string.format(" (%d日後)", diff)
									or string.format(" (In %d days)", diff)
							end
						end

						-- Highlight the due date string
						vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, d_s - 1, {
							end_col = d_s - 1 + #d_str,
							hl_group = hl,
							ephemeral = false,
						})

						-- Virtual text at end of line
						if vtext ~= "" then
							vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
								virt_text = { { vtext, hl } },
								virt_text_pos = "eol",
								hl_mode = "combine",
							})
						end
					end

					-- 5. Task ID (id:xxxxxx): 内部識別用で人間が読む必要は無いため conceal で隠す。
					-- M.setup() で concealcursor を空にしているため、カーソルがその行にある間は
					-- 自動的に見える状態に戻り、通常通り編集できる(バッファの中身は変更しない)。
					local id_s, id_full = line:match("()(%s+id:%S+)%s*$")
					if id_s then
						vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, id_s - 1, {
							end_col = id_s - 1 + #id_full,
							conceal = "",
							ephemeral = false,
						})
					end
				end
			end
		end)
		if not ok then
			vim.notify("GTodo highlight error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end)
end

-- 指定されたバッファに対してハイライト自動更新をセットアップする
function M.attach(bufnr)
	if not bufnr or bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end

	-- 初回実行
	M.update_highlights(bufnr)

	-- 文字入力などで変更されるたびにハイライトを更新する
	local group = vim.api.nvim_create_augroup("GTodoHighlight_" .. bufnr, { clear = true })

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = bufnr,
		callback = function()
			M.update_highlights(bufnr)
		end,
	})
end

return M
