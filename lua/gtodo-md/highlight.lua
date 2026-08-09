local M = {}
local ns = vim.api.nvim_create_namespace("gtodo_highlights")
local utils = require("gtodo-md.utils")
local task_mod = require("gtodo-md.task")

-- conceal_tags(リスト)を検索しやすい集合へ直す。
-- 未知のタグ名は単に一致せず何も起きない(意図的に検証しない)。
local function build_conceal_set()
	local set = {}
	local configured = require("gtodo-md.config").get("conceal_tags")
	if type(configured) ~= "table" then
		return set
	end
	for _, name in ipairs(configured) do
		if type(name) == "string" then
			set[name] = true
		end
	end
	return set
end

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
-- 行から優先度 `(A)` の開始位置と文字列を返す(純関数。テスト用に公開)。
--
-- task.lua のパース規則に合わせること: **チェックボックス直後かつ後ろスペース必須**。
-- 無アンカーで探すと本文中の "(B)" (例: "Reply about grade (B) to teacher") まで
-- 優先度としてハイライトし、task.lua が priority=nil と解釈している(＝ソートにも
-- 影響していない)タスクを、優先度付きであるかのようにユーザーへ見せてしまう。
function M._match_priority(line)
	return line:match("^%s*%-%s*%[[ xX]%]%s*()(%([A-Z]%))%s")
end

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

		-- 設定は setup() 後に変わりうるので、描画のたびに読み直す(行ごとではなく1回)。
		local conceal_set = build_conceal_set()

		local ok, err = pcall(function()
			-- 既存のハイライトをクリア
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local today_time = utils.date_to_time(os.date("%Y-%m-%d"))

			-- ロケール判定は1回の update_highlights 呼び出し内では不変なので、
			-- due日付を持つ行ごとにループの内側で計算せずここで1回だけ行う。
			local lang = type(vim.v.lang) == "string" and vim.v.lang or os.getenv("LANG") or ""
			local time_lang = os.setlocale(nil, "time") or ""
			local is_ja = string.match(lang, "^ja")
			if string.match(time_lang, "^en") then
				is_ja = false
			elseif string.match(time_lang, "^ja") then
				is_ja = true
			end

			for i, line in ipairs(lines) do
				if utils.is_todo_line(line) or utils.is_done_line(line) then
					-- 1・2. Project tag (+Project) / Context (@context)
					-- 位置の特定は task.tag_ranges に委ねる(第2引数でproject/contextも含める)。
					-- M._match_priority/due日付と同じ考え方で、無アンカーの独自正規表現による
					-- 本文中の同型文字列(例: メールの `+work`/`@example.com`)の誤検出を避ける。
					for _, r in ipairs(task_mod.tag_ranges(line, true)) do
						if r.key == "project" or r.key == "context" then
							-- tag_ranges の範囲は直前の空白を含むため、ハイライトが
							-- タグ自体(+/@から)に始まるよう先頭の空白を読み飛ばす。
							local raw = line:sub(r.start_col + 1, r.end_col)
							local lead = raw:match("^%s*")
							local tag_start = r.start_col + #lead
							vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, tag_start, {
								end_col = r.end_col,
								hl_group = r.key == "project" and hl_groups.project or hl_groups.context,
								ephemeral = false,
							})
						end
					end

					-- 3. Priority ((A), (B), (C))
					local p_s, p_c = M._match_priority(line)
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
					-- 位置の特定は task.tag_ranges に委ねる。M._match_priority と同じ考え方で、
					-- 無アンカーの独自正規表現による本文中の同型文字列の誤検出を避ける。
					local d_s, d_str
					for _, r in ipairs(task_mod.tag_ranges(line)) do
						if r.key == "due" then
							local raw = vim.trim(line:sub(r.start_col + 1, r.end_col))
							if raw:match("^due:%d%d%d%d%-%d%d%-%d%d$") then
								d_str = raw
								d_s = r.end_col - #raw + 1
							end
							break
						end
					end
					if d_s then
						local date_val = d_str:sub(5)
						local due_time = utils.date_to_time(date_val)
						local hl = hl_groups.date_normal
						local vtext = ""

						if due_time then
							local diff = math.floor((due_time - today_time) / 86400)

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

					-- 5. conceal_tags で指定された `key:value` タグを隠す。
					-- 既定は `id` のみ(内部識別用で人間が読む必要が無いため)。
					-- M.setup() で concealcursor を空にしているため、カーソルがその行にある間は
					-- 自動的に見える状態に戻り、通常通り編集できる(バッファの中身は変更しない)。
					--
					-- 位置の特定は task.tag_ranges に委ねる。ここで正規表現を組み直すと、
					-- task.lua がタグ順序を変えたときに黙って追従できなくなる。
					if next(conceal_set) ~= nil then
						for _, r in ipairs(task_mod.tag_ranges(line)) do
							if conceal_set[r.key] then
								vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, r.start_col, {
									end_col = r.end_col,
									conceal = "",
									ephemeral = false,
								})
							end
						end
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
	local group_name = "GTodoHighlight_" .. bufnr
	local group = vim.api.nvim_create_augroup(group_name, { clear = true })

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = bufnr,
		callback = function()
			M.update_highlights(bufnr)
		end,
	})

	-- バッファが閉じて別番号で再度開かれるたびに空のaugroupが蓄積し続けるのを防ぐ。
	-- autocmds.lua の original_history_sections/original_created_dates の
	-- BufWipeout クリアと同じ考え方(#125等)。
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = bufnr,
		once = true,
		callback = function()
			pending_updates[bufnr] = nil
			pcall(vim.api.nvim_del_augroup_by_name, group_name)
		end,
	})
end

return M
