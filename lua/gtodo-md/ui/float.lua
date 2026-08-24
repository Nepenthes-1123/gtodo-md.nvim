local M = {}
local config = require("gtodo-md.config")

-- 現在開いている「排他的な」ビュー(todo/inbox/done/cancelledのフロート、Queue、
-- Kanban等)を閉じるためのクロージャを1つだけ保持する。次に別のビューを開く際は、
-- まずこれを呼んで前のビューを閉じてから、新しいビューの閉じ方に差し替える。
-- 単一ウィンドウとは限らない(Kanbanは複数ウィンドウを1つのビューとして扱う)ため、
-- ウィンドウIDそのものではなく「閉じ方(関数)」を持つ形に一般化してある。
local active_closer = nil

-- open_float が張る WinLeave の置き場。clear=false で作る —
-- clear=true にすると、別ファイルのフロートが張った登録まで巻き添えで消える。
local float_augroup = vim.api.nvim_create_augroup("GtodoMdFloat", { clear = false })

-- 現在の排他ビューを閉じる。呼び出し前に active_closer を nil へ戻してから
-- closer を呼ぶ(再入防止。closer の実装が何らかの経路でこの関数を呼び返しても、
-- 既に nil になっているため二重にクローズ処理が走らない)。
function M.close_current_float()
	local closer = active_closer
	if closer then
		active_closer = nil
		closer()
	end
end

-- 新しい排他ビューを登録する。まず現在の排他ビュー(あれば)を閉じてから、
-- 渡された closer_fn を次の「閉じ方」として登録する。
-- closer_fn は引数を取らない関数で、既に閉じている状態で呼ばれても安全である
-- (冪等)必要がある。
function M.register_active_view(closer_fn)
	M.close_current_float()
	active_closer = closer_fn
end

-- 単一ウィンドウのビュー(todo/inbox/done/cancelledのフロート、Queue)向けの
-- 薄いラッパー。register_active_view の外部APIはそのままに、既存の呼び出し元
-- (open_float / ui/queue.lua の open_queue_window 等)は変更不要。
function M.register_float_win(win)
	M.register_active_view(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end)
end

-- フローティングウィンドウでファイルを開く
function M.open_float(filepath, title)
	title = title or vim.fn.fnamemodify(filepath, ":t")
	-- 既存のgtodoフロートを閉じてから新しく開く
	M.close_current_float()

	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.8)
	local col = math.floor((vim.o.columns - width) / 2)
	local row = math.floor((vim.o.lines - height) / 2)

	local opts = {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	}

	-- 1. ファイルを裏側でバッファとして登録
	local file_buf = vim.fn.bufadd(filepath)

	-- 2. 読み込む前に即座にタブ一覧から除外する
	vim.bo[file_buf].buflisted = false

	-- 3. ファイルの内容と色付け(Syntax/Filetype)をロードする
	vim.fn.bufload(file_buf)

	-- 4. 用意したバッファで直接フローティングウィンドウを開く
	local win = vim.api.nvim_open_win(file_buf, true, opts)
	M.register_float_win(win)

	-- 5. 賢いゾンビ化対策（自動保存＆条件付きクローズ）
	--
	-- augroup へ入れたうえで、同じバッファ向けの登録を毎回消してから張り直す。
	-- open_float は同じファイルに対して繰り返し呼ばれる(キーマップを使うたび)ため、
	-- 無条件登録のままだと WinLeave が1回発火するたびに :write とウィンドウクローズが
	-- 開いた回数だけ実行される。augroup 自体は clear=false で作る — clear=true にすると
	-- 別ファイルのフロートの登録まで巻き添えで消える。
	vim.api.nvim_clear_autocmds({ group = float_augroup, buffer = file_buf })
	vim.api.nvim_create_autocmd("WinLeave", {
		group = float_augroup,
		buffer = file_buf,
		callback = function()
			-- フォーカスが外れたらまずは安全のために保存。
			--
			-- #125: この `:write` は autocmd の中で実行されるため、autocmd が
			-- 既定でネストしない仕様により BufWritePost が発火しない。つまり
			-- autocmds.lua の記録契機を素通りし、ディスクだけが進んで io.lua の
			-- 世代スタンプが取り残される。
			-- ここで record_stamp を呼んで補ってはならない — `silent!` は失敗を
			-- 握り潰すため、書き込みが失敗していた場合に「他インスタンスが書いた
			-- 内容」を同期済みと刻印してしまい、並行更新検出を無効化する。
			-- 取り残されたスタンプは io.lua の disk_matches_buffer が回収する。
			vim.cmd("silent! write")

			vim.schedule(function()
				if not vim.api.nvim_win_is_valid(win) then
					return
				end

				local cur_win = vim.api.nvim_get_current_win()
				local win_config = vim.api.nvim_win_get_config(cur_win)

				-- 次のウィンドウが通常の画面（relative == ""）であれば、本来の作業に戻ったと判断して閉じる
				if win_config.relative == "" then
					pcall(vim.api.nvim_win_close, win, false)
				end
			end)
		end,
	})

	return file_buf, win
end

function M.open_todo_float()
	local path = config.get("data_dir") .. "/todo.md"
	M.open_float(path, "Todo")
end

function M.open_inbox_float()
	local path = config.get("data_dir") .. "/inbox.md"
	M.open_float(path, "Inbox")
end

function M.open_done_float()
	local path = config.get("data_dir") .. "/done.md"
	M.open_float(path, "Done")
end

function M.open_cancelled_float()
	local path = config.get("data_dir") .. "/cancelled.md"
	M.open_float(path, "Cancelled")
end

return M
