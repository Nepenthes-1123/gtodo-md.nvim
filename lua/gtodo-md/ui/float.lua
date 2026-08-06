local M = {}
local config = require("gtodo-md.config")

-- 現在開いているgtodoフローティングウィンドウ (1つだけ管理)
local gtodo_float_win = nil

function M.close_current_float()
	if gtodo_float_win and vim.api.nvim_win_is_valid(gtodo_float_win) then
		vim.api.nvim_win_close(gtodo_float_win, true)
	end
	gtodo_float_win = nil
end

function M.register_float_win(win)
	gtodo_float_win = win
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
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = file_buf,
		callback = function()
			-- フォーカスが外れたらまずは安全のために保存
			vim.cmd("silent! write")

			-- #125: この `:write` は autocmd の中で実行されるため、autocmd が
			-- 既定でネストしない仕様により **BufWritePost が発火しない**。
			-- つまり autocmds.lua の記録契機を素通りし、ディスクだけが進んで
			-- io.lua の世代スタンプが取り残される。その状態で自動処理が走ると
			-- 「他のプロセスによって更新されています」と誤検知する。
			-- 観測できない同期点なので、書いた側から明示的に記録する。
			pcall(require("gtodo-md.io").record_stamp, vim.api.nvim_buf_get_name(file_buf))

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
