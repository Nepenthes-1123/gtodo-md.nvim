-- Kanban ビュー: todo.md の Someday/Next/Today/Waiting 各セクション + done.md の
-- 内容を、列ごとに独立したフローティングウィンドウで可視化する。
--
-- 新規のタグ・データモデルは一切追加しない。既存の task.lua/io.lua/editor.lua の
-- データ・操作をそのまま再利用し、カンバン側は「表示」と「(カーソル非依存の)
-- 操作リクエストの発行」だけを担う。カードの移動・完了トグルは実際には
-- editor.lua がtodo.mdへ書き込むだけで、カンバンのバッファを直接書き換えることは
-- しない。書き込み後は io.add_write_observer 経由の再描画通知だけで表示を
-- 更新する(ui/project.lua と同じパターン)。
--
-- v1のスコープ外(意図的な判断。要件定義時点での合意): カード上でのタスク本文編集、
-- cancelled.md の表示およびカンバンからのキャンセル操作、Undo/Redo。
-- cancelled.md を含めないのは実装漏れではなく、カンバンは「実行中のワークフロー」
-- (Someday/Next/Today/Waiting/Done)を可視化する画面と位置付け、終了済みの記録である
-- done.md/cancelled.md のうち done.md(完了)だけを対象に含める設計判断による。
local M = {}

local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")
local utils = require("gtodo-md.utils")
local editor_mod = require("gtodo-md.editor")
local float_ui = require("gtodo-md.ui.float")

local BORDER_H = "─"
local BORDER_V = "│"
local BORDER_TL, BORDER_TR, BORDER_BL, BORDER_BR = "┌", "┐", "└", "┘"

local MIN_COL_WIDTH = 20
local MAX_COL_WIDTH = 56
local COL_GAP = 1
local OUTER_MARGIN = 1
-- ウィンドウの罫線(border="rounded")が左右に1文字ずつ占める幅。5列を並べる際の
-- 必要幅の見積りにこの分を含めないと、実際の画面幅より過大に列数を選んでしまい、
-- 右端の列が画面外へはみ出す。
local WIN_BORDER_WIDTH = 2

-- カンバン列の並び順(仕様で固定): Someday / Next / Today / Waiting / Done
local COLUMN_KEYS = { "SOMEDAY", "NEXT", "TODAY", "WAITING", "DONE" }

--- 純関数群(バッファ/ウィンドウに触れない) -----------------------------------

-- 表示幅に収まるよう文字列を切り詰める(超過分は "…" で示す)。日本語等の
-- 全角文字を考慮し、strdisplaywidth/strcharpart で1文字ずつ削る。
function M._truncate_to_width(text, max_width)
	if vim.fn.strdisplaywidth(text) <= max_width then
		return text
	end
	local ellipsis = "…"
	local budget = math.max(0, max_width - vim.fn.strdisplaywidth(ellipsis))
	local result = text
	while vim.fn.strdisplaywidth(result) > budget and vim.fn.strchars(result) > 0 do
		result = vim.fn.strcharpart(result, 0, vim.fn.strchars(result) - 1)
	end
	return result .. ellipsis
end

-- 表示幅ぴったりになるよう末尾に半角スペースを埋める。
function M._pad_to_width(text, width)
	local w = vim.fn.strdisplaywidth(text)
	if w >= width then
		return text
	end
	return text .. string.rep(" ", width - w)
end

-- due日付の相対表示テキストを組み立てる(ui/queue.lua の date_label と同じ考え方の
-- 日数差計算を流用。カンバンのカードは独自に組み立てた文字列であり task.tag_ranges の
-- 対象になる生のmarkdown行ではないため、ここでは値から直接組み立てる)。
local function due_tag_text(due_date, today_time)
	local t = utils.date_to_time(due_date)
	local diff = math.floor((t - today_time) / 86400)
	if diff < 0 then
		return string.format("due:%s (%d日超過)", due_date, -diff)
	elseif diff == 0 then
		return string.format("due:%s (今日)", due_date)
	elseif diff == 1 then
		return string.format("due:%s (明日)", due_date)
	else
		return string.format("due:%s (%d日後)", due_date, diff)
	end
end

-- due日付の色分け(既存の highlight.lua が定義するハイライトグループをそのまま使う)。
local function due_hl(due_date, today_time)
	local t = utils.date_to_time(due_date)
	local diff = math.floor((t - today_time) / 86400)
	if diff < 0 then
		return "GTodoDateError"
	elseif diff == 0 then
		return "GTodoDateWarn"
	else
		return "GTodoDate"
	end
end

-- 1タスクをカード内側(罫線を除く)の行群へ変換する(純関数)。
-- 戻り値: lines(内側の表示行配列。各行は inner_width ぴったりにパディング済み)、
--         spans( { line=(1-indexed, linesに対応), start_col=, end_col=, hl_group= } の配列。
--         start_col/end_col は該当行のバイトオフセット(0-indexed, end排他) )
function M._card_body_lines(task, inner_width, today_time)
	today_time = today_time or utils.date_to_time(os.date("%Y-%m-%d"))

	local checkbox = (task.status == "x") and "[x]" or "[ ]"
	local priority_text = (task.priority and task.priority ~= "") and ("(" .. task.priority .. ") ") or ""
	local head = " " .. checkbox .. " " .. priority_text .. (task.content or "")
	local first = M._pad_to_width(M._truncate_to_width(head, inner_width), inner_width)

	local spans = {}
	if priority_text ~= "" then
		local prefix_len = #(" " .. checkbox .. " ")
		local hl = "GTodoPriorityC"
		if task.priority == "A" then
			hl = "GTodoPriorityA"
		elseif task.priority == "B" then
			hl = "GTodoPriorityB"
		end
		table.insert(spans, { line = 1, start_col = prefix_len, end_col = prefix_len + 3, hl_group = hl })
	end

	local lines = { first }

	-- タグ(@context/+project/due:/wait:/done:/completed:)を組み立てる。
	-- id/created 等の内部向けタグは表示しない(task.lua の NON_INHERITABLE_TAGS と
	-- 同じ考え方で、人間が読む必要のない情報を除外する)。
	local tags = {}
	if task.context and task.context ~= "" then
		local c = task.context
		table.insert(tags, { text = c:match("^@") and c or ("@" .. c), hl = "GTodoContext" })
	end
	if task.project and task.project ~= "" then
		table.insert(tags, { text = "+" .. task.project, hl = "GTodoProject" })
	end
	if task.due and task.due ~= "" then
		table.insert(tags, { text = due_tag_text(task.due, today_time), hl = due_hl(task.due, today_time) })
	end
	if task.wait and task.wait ~= "" then
		table.insert(tags, { text = "wait:" .. task.wait, hl = "GTodoWait" })
	end
	if task.done and task.done ~= "" then
		table.insert(tags, { text = "done:" .. task.done, hl = "GTodoDate" })
	elseif task.completed_at and task.completed_at ~= "" then
		table.insert(tags, { text = "completed:" .. task.completed_at, hl = "GTodoDate" })
	end

	if #tags > 0 then
		local cur = " "
		local cur_spans = {}
		local function flush()
			table.insert(lines, M._pad_to_width(cur, inner_width))
			local line_idx = #lines
			for _, s in ipairs(cur_spans) do
				table.insert(spans, { line = line_idx, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl })
			end
			cur = " "
			cur_spans = {}
		end
		for _, tag in ipairs(tags) do
			local sep = (cur == " ") and "" or " "
			local candidate = cur .. sep .. tag.text
			if vim.fn.strdisplaywidth(candidate) > inner_width and cur ~= " " then
				flush()
				candidate = cur .. tag.text
			end
			local start_col = #candidate - #tag.text
			table.insert(cur_spans, { start_col = start_col, end_col = start_col + #tag.text, hl = tag.hl })
			cur = candidate
		end
		if cur ~= " " then
			flush()
		end
	end

	return lines, spans
end

-- カード配列から、列バッファの全表示行・カード境界(line_map相当)・ハイライトスパンを
-- 組み立てる(純関数)。width はカード全体(左右の罫線を含む)の表示幅。
-- 戻り値: lines, ranges( { task_id=, start_line=, end_line=(いずれもlinesの1-indexed), card= } ),
--         hl_spans( { line=, start_col=, end_col=, hl_group= }(いずれもバッファ座標) )
function M._render_column_lines(cards, width, today_time)
	if #cards == 0 then
		return { "  (no tasks)" }, {}, {}
	end

	local inner_width = math.max(1, width - 2)
	local lines = {}
	local ranges = {}
	local hl_spans = {}

	for _, card in ipairs(cards) do
		local body_lines, spans = M._card_body_lines(card.task, inner_width, today_time)
		local start_line = #lines + 1
		table.insert(lines, BORDER_TL .. string.rep(BORDER_H, inner_width) .. BORDER_TR)
		for _, bl in ipairs(body_lines) do
			table.insert(lines, BORDER_V .. bl .. BORDER_V)
		end
		table.insert(lines, BORDER_BL .. string.rep(BORDER_H, inner_width) .. BORDER_BR)
		local end_line = #lines

		for _, s in ipairs(spans) do
			table.insert(hl_spans, {
				line = start_line + s.line,
				start_col = #BORDER_V + s.start_col,
				end_col = #BORDER_V + s.end_col,
				hl_group = s.hl_group,
			})
		end

		table.insert(ranges, { task_id = card.task.id, start_line = start_line, end_line = end_line, card = card })
	end

	return lines, ranges, hl_spans
end

-- todo_data(todo.mdをparse_markdownしたもの)・done_data(done.mdを同様にparseしたもの)から
-- 5列分のカードを組み立てる(純関数)。sections は config.sections 相当のテーブル
-- ({SOMEDAY=,NEXT=,TODAY=,WAITING=} の名称)。
--
-- 未完了タスクは todo.md の対応セクションへ、完了(status=="x")タスクは
-- (rollover待ちのものも含めて)すべて Done 列へ集約する。これにより、
-- Today等の列とDone列でタスクが二重に表示されることを防ぐ
-- (todo.mdの1タスクは常にどれか1列にのみ属する)。
function M._build_columns(todo_data, done_data, sections)
	local order = { "SOMEDAY", "NEXT", "TODAY", "WAITING" }
	local columns = {}
	local by_key = {}
	for _, key in ipairs(order) do
		local col = { key = key, title = sections[key], cards = {} }
		table.insert(columns, col)
		by_key[key] = col
	end
	local done_col = { key = "DONE", title = "Done", cards = {} }
	table.insert(columns, done_col)

	for _, key in ipairs(order) do
		local sec_name = sections[key]
		local items = (todo_data.sections or {})[sec_name] or {}
		for _, item in ipairs(items) do
			if item.type == "task" then
				if item.task.status == "x" then
					table.insert(done_col.cards, { task = item.task, source = "todo", section = sec_name })
				else
					table.insert(by_key[key].cards, { task = item.task, source = "todo", section = sec_name })
				end
			end
		end
	end

	for _, sec_name in ipairs(done_data.section_order or {}) do
		local items = (done_data.sections or {})[sec_name] or {}
		for _, item in ipairs(items) do
			if item.type == "task" then
				table.insert(done_col.cards, { task = item.task, source = "done" })
			end
		end
	end

	-- 新しく完了したものが上に来るよう、done(またはrollover待ちはcompleted_at)の
	-- 降順に並べる。table.sort は安定ソートではないため同日内の順序までは保証しない。
	table.sort(done_col.cards, function(a, b)
		local da = a.task.done or a.task.completed_at or ""
		local db = b.task.done or b.task.completed_at or ""
		return da > db
	end)

	return columns
end

-- 画面幅から、一度に表示できる列数と1列あたりの幅を決める(純関数)。
-- avail_width は列を並べる領域全体の表示幅で、各列のウィンドウ罫線
-- (WIN_BORDER_WIDTH)ぶんも含めて見積もる(実際に画面へ配置する際の
-- 消費幅と一致させ、右端の列が画面外へはみ出すのを防ぐため)。
function M._compute_layout(total_columns, avail_width, avail_height)
	local unit = MIN_COL_WIDTH + WIN_BORDER_WIDTH
	local visible_count = math.max(1, math.min(total_columns, math.floor((avail_width + COL_GAP) / (unit + COL_GAP))))
	local col_width = math.floor((avail_width - COL_GAP * (visible_count - 1)) / visible_count) - WIN_BORDER_WIDTH
	col_width = math.max(MIN_COL_WIDTH, math.min(MAX_COL_WIDTH, col_width))
	return { visible_count = visible_count, col_width = col_width, height = avail_height }
end

-- focus_index(1-indexed)が可視範囲に入るよう、必要なら page_offset をずらす(純関数)。
-- 既に可視範囲内ならそのまま返す。
function M._clamp_page_offset(focus_index, visible_count, total_columns, current_offset)
	local max_offset = math.max(0, total_columns - visible_count)
	local offset = math.max(0, math.min(current_offset or 0, max_offset))
	if focus_index < offset + 1 then
		offset = focus_index - 1
	elseif focus_index > offset + visible_count then
		offset = focus_index - visible_count
	end
	return math.max(0, math.min(offset, max_offset))
end

-- カーソル行(1-indexed)が属するカードの range を返す(純関数)。
function M._find_card_at_line(ranges, line)
	for _, r in ipairs(ranges) do
		if line >= r.start_line and line <= r.end_line then
			return r
		end
	end
	return nil
end

-- j/k でのカード間移動先の行番号を計算する(純関数)。
-- カーソルがどのカードにも属さない場合は、移動方向に応じて最寄りのカードへ飛ぶ。
-- 移動できない(先頭/末尾)場合は nil。
function M._adjacent_card_index(ranges, current_line, delta)
	if #ranges == 0 then
		return nil
	end

	local idx = nil
	for i, r in ipairs(ranges) do
		if current_line >= r.start_line and current_line <= r.end_line then
			idx = i
			break
		end
	end

	if idx then
		idx = idx + delta
		if idx < 1 or idx > #ranges then
			return nil
		end
	elseif delta > 0 then
		for i, r in ipairs(ranges) do
			if r.start_line > current_line then
				idx = i
				break
			end
		end
		idx = idx or #ranges
	else
		for i = #ranges, 1, -1 do
			if ranges[i].start_line < current_line then
				idx = i
				break
			end
		end
		idx = idx or 1
	end

	return ranges[idx].start_line
end

--- UI(バッファ/ウィンドウ/キーマップ) --------------------------------------

local kanban_ns = vim.api.nvim_create_namespace("gtodo_kanban")
local selected_ns = vim.api.nvim_create_namespace("gtodo_kanban_selected")
-- 個々のウィンドウ/バッファに紐づく autocmd(WinClosed/BufWipeout/CursorMoved)専用。
-- render() が(内容だけの更新で済まず)作り直しを行うたびに、古い登録を明示的に
-- クリアしてから作り直す。クリアしないと、既に閉じられて二度と発火しない
-- WinClosed/BufWipeoutの登録が再描画のたびに際限なく積み上がってしまう。
local AUGROUP = vim.api.nvim_create_augroup("GtodoMdKanban", { clear = true })
-- ウィンドウ/バッファに依存せず、モジュールの寿命ぶんだけ張りっぱなしにする
-- autocmd(VimResized)専用。AUGROUP は render() のたびにクリアされるため、
-- そちらに登録すると初回の作り直しで消えてしまう。
local GLOBAL_AUGROUP = vim.api.nvim_create_augroup("GtodoMdKanbanGlobal", { clear = true })

local state = {
	wins = {}, -- 現在開いているウィンドウ(可視列の分だけ)
	bufs = {}, -- 対応するバッファ
	col_keys = {}, -- state.wins/bufs と同じ並びの列key
	visible_indices = {}, -- 同上。COLUMN_KEYS上のインデックス(1..5)
	card_ranges = {}, -- [key] = ranges (直近の描画結果。非表示列も直前の値を保持する)
	last_view = {}, -- [key] = winsaveview() の結果
	last_task_id = {}, -- [key] = カーソルがあったカードのtask id
	page_offset = 0,
	focus_col_index = 1,
	is_open = false,
	closing = false,
	last_layout_col_width = nil, -- 直近の描画に使ったレイアウト(内容だけの更新が可能かの判定に使う)
	last_layout_height = nil,
}

local render
local focus_column

-- ウィンドウ/バッファのいずれか1枚でも閉じられたら、残り全部を道連れに閉じる。
local function close_kanban()
	if state.closing or not state.is_open then
		return
	end
	state.closing = true
	for _, win in ipairs(state.wins) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	for _, buf in ipairs(state.bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	state.wins = {}
	state.bufs = {}
	state.col_keys = {}
	state.visible_indices = {}
	state.is_open = false
	state.closing = false
end
M.close_kanban = close_kanban

-- #92(split.lua)と同じ考え方: BufWipeout/WinClosed の両方から冪等にクリーンアップする。
-- redraw(再描画)のための内部的な close は state.closing で明示的に区別しており、
-- そちらではこのコールバックを再入させない。
local function register_cleanup(win, buf)
	vim.api.nvim_create_autocmd("WinClosed", {
		group = AUGROUP,
		pattern = tostring(win),
		callback = function()
			if state.closing then
				return
			end
			close_kanban()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = AUGROUP,
		buffer = buf,
		callback = function()
			if state.closing then
				return
			end
			close_kanban()
		end,
	})
end

local function apply_highlight_spans(buf, spans)
	for _, s in ipairs(spans) do
		pcall(vim.api.nvim_buf_add_highlight, buf, kanban_ns, s.hl_group, s.line - 1, s.start_col, s.end_col)
	end
end

-- 選択中カードの背景+罫線ハイライトを再計算する。
local function highlight_current_card(buf, win, key)
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, selected_ns, 0, -1)

	local ranges = state.card_ranges[key] or {}
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
	if not ok then
		return
	end
	local range = M._find_card_at_line(ranges, cursor[1])
	if not range then
		return
	end

	local border_bytes = #BORDER_V
	for l = range.start_line, range.end_line do
		if l == range.start_line or l == range.end_line then
			-- 罫線のみの行(上端/下端)はそのまま全体を罫線色にする
			vim.api.nvim_buf_add_highlight(buf, selected_ns, "GTodoKanbanSelectedBorder", l - 1, 0, -1)
		else
			local text = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
			vim.api.nvim_buf_add_highlight(buf, selected_ns, "GTodoKanbanSelectedBorder", l - 1, 0, border_bytes)
			vim.api.nvim_buf_add_highlight(
				buf,
				selected_ns,
				"GTodoKanbanSelectedBg",
				l - 1,
				border_bytes,
				math.max(border_bytes, #text - border_bytes)
			)
			vim.api.nvim_buf_add_highlight(
				buf,
				selected_ns,
				"GTodoKanbanSelectedBorder",
				l - 1,
				math.max(border_bytes, #text - border_bytes),
				-1
			)
		end
	end
end

-- カーソル/スクロール位置を可能な範囲で復元する。
-- task_id が新しい ranges に見つかればそのカードの先頭行へ、見つからなければ
-- (削除・他インスタンスでの変更等)以前の行番号をクランプするだけに留める。
local function restore_view(win, buf, ranges, task_id, old_view)
	local total = vim.api.nvim_buf_line_count(buf)
	local target_line = nil

	if task_id then
		for _, r in ipairs(ranges) do
			if r.task_id == task_id then
				target_line = r.start_line
				break
			end
		end
	end

	if not target_line then
		target_line = math.max(1, math.min((old_view and old_view.lnum) or 1, total))
	end

	pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })

	if old_view then
		local offset = old_view.lnum - old_view.topline
		local new_topline = math.max(1, target_line - offset)
		pcall(vim.api.nvim_win_call, win, function()
			vim.fn.winrestview({ topline = new_topline })
		end)
	end
end

local function goto_adjacent_card(win, key, delta)
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
	if not ok then
		return
	end
	local target = M._adjacent_card_index(state.card_ranges[key] or {}, cursor[1], delta)
	if target then
		vim.api.nvim_win_set_cursor(win, { target, 0 })
	end
end

local function move_card_to(range, target_section)
	if not range then
		return
	end
	local card = range.card
	if card.source == "done" then
		vim.notify("[gtodo-md] Cannot move a task recorded in done.md from the Kanban view.", vim.log.levels.WARN)
		return
	end
	editor_mod.request_move_task_to(card.task, card.section, target_section)
end

local function toggle_card_done(range)
	if not range then
		return
	end
	local card = range.card
	if card.source == "done" then
		vim.notify("[gtodo-md] Cannot change a task recorded in done.md from the Kanban view.", vim.log.levels.WARN)
		return
	end

	local is_completed = card.task.status == "x"
	if not is_completed then
		-- 完了後の実際のdone.mdへの物理移動は日次ロールオーバー等の別プロセスで
		-- 発生し、それが先に走ると事実上元に戻す手段がなくなるため、
		-- 完了(x)方向への変更にだけ軽い確認を挟む。
		local choice = vim.fn.confirm("Mark task as done?", "&Yes\n&No")
		if choice ~= 1 then
			return
		end
	end

	editor_mod.toggle_task_complete(card.task, card.section)
end

local function setup_card_keymaps(buf, win, key)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, noremap = true, silent = true, desc = desc })
	end

	local function current_card()
		local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
		if not ok then
			return nil
		end
		return M._find_card_at_line(state.card_ranges[key] or {}, cursor[1])
	end

	map("j", function()
		goto_adjacent_card(win, key, 1)
	end, "Next card")
	map("k", function()
		goto_adjacent_card(win, key, -1)
	end, "Previous card")
	map("h", function()
		focus_column(-1)
	end, "Focus previous column")
	map("l", function()
		focus_column(1)
	end, "Focus next column")

	map("d", function()
		move_card_to(current_card(), config.sections.TODAY)
	end, "Move card to " .. config.sections.TODAY)
	map("n", function()
		move_card_to(current_card(), config.sections.NEXT)
	end, "Move card to " .. config.sections.NEXT)
	map("w", function()
		move_card_to(current_card(), config.sections.WAITING)
	end, "Move card to " .. config.sections.WAITING .. " (set wait:)")
	map("s", function()
		move_card_to(current_card(), config.sections.SOMEDAY)
	end, "Move card to " .. config.sections.SOMEDAY)
	map("x", function()
		toggle_card_done(current_card())
	end, "Toggle card done")

	map("q", function()
		close_kanban()
	end, "Close Kanban view")
	map("<Esc>", function()
		close_kanban()
	end, "Close Kanban view")
end

-- 5列(COLUMN_KEYS)ぶんのデータを集める。
local function collect_columns()
	local data_dir = config.get("data_dir")
	local todo_data = io_mod.read_todo_file(data_dir .. "/todo.md")
	local done_data = io_mod.read_todo_file(data_dir .. "/done.md")
	local today_time = utils.date_to_time(os.date("%Y-%m-%d"))
	return M._build_columns(todo_data, done_data, config.sections), today_time
end

local function arrays_equal(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function all_wins_bufs_valid()
	for _, w in ipairs(state.wins) do
		if not vim.api.nvim_win_is_valid(w) then
			return false
		end
	end
	for _, b in ipairs(state.bufs) do
		if not vim.api.nvim_buf_is_valid(b) then
			return false
		end
	end
	return true
end

-- 可視列の構成とレイアウト(列幅・高さ)が前回描画時と変わらない場合に、
-- ウィンドウ/バッファを閉じて作り直さず、内容(行・ハイライト・タイトル)だけを
-- 更新する。トリアージ操作(カードを1件動かすたびに書き込みオブザーバ経由で
-- 再描画される、本機能の主要ユースケース)で、無関係な列まで含めて毎回
-- ちらつくのを避けるための最適化。ページング・リサイズ等で可視列やレイアウトが
-- 変わる場合は render() 側の判定でこの関数を使わず作り直す。
local function update_columns_in_place(visible_indices, columns, layout, today_time)
	for i, col_index in ipairs(visible_indices) do
		local column = columns[col_index]
		local win = state.wins[i]
		local buf = state.bufs[i]
		local key = state.col_keys[i]

		local prev_view, prev_task_id = nil, nil
		local ok, view = pcall(vim.api.nvim_win_call, win, function()
			return vim.fn.winsaveview()
		end)
		if ok then
			prev_view = view
			local range = M._find_card_at_line(state.card_ranges[key] or {}, view.lnum)
			if range then
				prev_task_id = range.task_id
			end
		end

		local lines, ranges, hl_spans = M._render_column_lines(column.cards, layout.col_width, today_time)
		state.card_ranges[key] = ranges

		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false

		vim.api.nvim_buf_clear_namespace(buf, kanban_ns, 0, -1)
		apply_highlight_spans(buf, hl_spans)

		pcall(vim.api.nvim_win_set_config, win, { title = string.format(" %s (%d) ", column.title, #column.cards) })

		restore_view(win, buf, ranges, prev_task_id, prev_view)
		highlight_current_card(buf, win, key)
	end
end

-- (再)描画する。focus_index(1-indexed, COLUMN_KEYS上の位置)を可視範囲に含めて
-- フォーカスする。他インスタンスの書き込み・due自動昇格・日次ロールオーバー等
-- による再描画もすべてこの関数を通る。
render = function(focus_index)
	focus_index = focus_index or state.focus_col_index or 1

	local columns, today_time = collect_columns()

	local avail_width = math.max(MIN_COL_WIDTH, vim.o.columns - OUTER_MARGIN * 2)
	local avail_height = math.max(10, math.floor(vim.o.lines * 0.8))
	local layout = M._compute_layout(#columns, avail_width, avail_height)
	local new_offset = M._clamp_page_offset(focus_index, layout.visible_count, #columns, state.page_offset)

	local visible_indices = {}
	for i = 1, layout.visible_count do
		table.insert(visible_indices, new_offset + i)
	end

	if
		state.is_open
		and layout.col_width == state.last_layout_col_width
		and layout.height == state.last_layout_height
		and arrays_equal(visible_indices, state.visible_indices)
		and all_wins_bufs_valid()
	then
		update_columns_in_place(visible_indices, columns, layout, today_time)
		state.page_offset = new_offset
		state.focus_col_index = focus_index
		return
	end

	-- 閉じる前に、現在表示中の各列のカーソル位置/スクロール位置を保存しておく。
	for i, key in ipairs(state.col_keys) do
		local win = state.wins[i]
		if win and vim.api.nvim_win_is_valid(win) then
			local ok, view = pcall(vim.api.nvim_win_call, win, function()
				return vim.fn.winsaveview()
			end)
			if ok then
				state.last_view[key] = view
				local range = M._find_card_at_line(state.card_ranges[key] or {}, view.lnum)
				if range then
					state.last_task_id[key] = range.task_id
				end
			end
		end
	end

	-- WinClosed/BufWipeout/CursorMoved の登録は作り直すたびに積み上がるため、
	-- 古い登録(既に閉じた/これから消えるウィンドウ・バッファを指すもの)を
	-- 明示的にクリアしてから作り直す。
	vim.api.nvim_clear_autocmds({ group = AUGROUP })
	close_kanban()

	local row = math.max(0, math.floor((vim.o.lines - layout.height) / 2))

	local new_wins, new_bufs, new_keys = {}, {}, {}
	local failed = false

	for i, col_index in ipairs(visible_indices) do
		local column = columns[col_index]
		local lines, ranges, hl_spans = M._render_column_lines(column.cards, layout.col_width, today_time)
		state.card_ranges[column.key] = ranges

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		-- ネイティブundo(u)を実質no-opにする。カンバンのバッファはtodo.md/done.mdの
		-- 内容を再描画するだけの表示専用バッファであり、バッファ内容への直接編集は
		-- 想定していない。undo履歴を残すと、実データ(todo.md)を変えない見た目だけの
		-- 巻き戻しができるように見えて誤操作を誘発するため、記録自体を無効化する。
		vim.bo[buf].undolevels = -1

		local x = OUTER_MARGIN + (i - 1) * (layout.col_width + WIN_BORDER_WIDTH + COL_GAP)
		local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
			relative = "editor",
			width = layout.col_width,
			height = layout.height,
			row = row,
			col = x,
			style = "minimal",
			border = "rounded",
			title = string.format(" %s (%d) ", column.title, #column.cards),
			title_pos = "center",
		})

		if not ok or not win then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
			failed = true
			break
		end

		vim.wo[win].wrap = false
		vim.wo[win].cursorline = false

		table.insert(new_wins, win)
		table.insert(new_bufs, buf)
		table.insert(new_keys, column.key)

		apply_highlight_spans(buf, hl_spans)
		setup_card_keymaps(buf, win, column.key)
		register_cleanup(win, buf)
		restore_view(win, buf, ranges, state.last_task_id[column.key], state.last_view[column.key])
		highlight_current_card(buf, win, column.key)

		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = AUGROUP,
			buffer = buf,
			callback = function()
				highlight_current_card(buf, win, column.key)
			end,
		})
	end

	if failed then
		for _, win in ipairs(new_wins) do
			pcall(vim.api.nvim_win_close, win, true)
		end
		for _, buf in ipairs(new_bufs) do
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		vim.notify("[gtodo-md] Failed to open Kanban view. Terminal size might be too small.", vim.log.levels.ERROR)
		return
	end

	state.wins = new_wins
	state.bufs = new_bufs
	state.col_keys = new_keys
	state.visible_indices = visible_indices
	state.page_offset = new_offset
	state.focus_col_index = focus_index
	state.last_layout_col_width = layout.col_width
	state.last_layout_height = layout.height
	state.is_open = true

	for i, idx in ipairs(visible_indices) do
		if idx == focus_index then
			pcall(vim.api.nvim_set_current_win, state.wins[i])
			break
		end
	end
end

-- 隣接列へフォーカスを移す。画面外の列であればページングしてから再描画する。
focus_column = function(delta)
	local new_index = state.focus_col_index + delta
	if new_index < 1 or new_index > #COLUMN_KEYS then
		return
	end

	for i, idx in ipairs(state.visible_indices) do
		if idx == new_index then
			state.focus_col_index = new_index
			pcall(vim.api.nvim_set_current_win, state.wins[i])
			return
		end
	end

	render(new_index)
end

-- ターミナルのリサイズに列レイアウト(表示できる列数・1列あたりの幅)を追従させる。
-- GLOBAL_AUGROUP に登録するため、render() が AUGROUP をクリアしても消えない。
vim.api.nvim_create_autocmd("VimResized", {
	group = GLOBAL_AUGROUP,
	callback = function()
		if state.is_open then
			render(state.focus_col_index)
		end
	end,
})

-- inbox.md/todo.md への書き込みで進捗表示を更新する ui/project.lua と同じパターン:
-- 書き込みが起きたことをここで拾い、Kanban表示中であれば再描画する。
-- 並行更新検出で書き込みが失敗した場合はオブザーバ自体が呼ばれないため、
-- 表示と実データが食い違うことはない。
io_mod.add_write_observer(function(path)
	if not state.is_open then
		return
	end
	local filename = vim.fn.fnamemodify(path, ":t")
	if filename ~= "todo.md" and filename ~= "done.md" then
		return
	end
	vim.schedule(function()
		if state.is_open then
			render(state.focus_col_index)
		end
	end)
end)

function M.setup()
	vim.api.nvim_set_hl(0, "GTodoKanbanSelectedBorder", { link = "Title", bold = true, default = true })
	vim.api.nvim_set_hl(0, "GTodoKanbanSelectedBg", { link = "CursorLine", default = true })
end

function M.open_kanban()
	-- todo/inbox/done/cancelledのフロートやQueueが開いていれば、まずそちらを閉じてから
	-- 開く(単一の排他ビューレジストリ経由。ui/float.lua参照)。逆方向(Kanban表示中に
	-- それらを開いた場合にKanbanが閉じること)は、それらが register_float_win 経由で
	-- 同じレジストリへ登録する際に自動的に成立する。
	float_ui.register_active_view(M.close_kanban)
	render(state.focus_col_index or 1)
end

return M
