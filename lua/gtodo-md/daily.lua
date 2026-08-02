local M = {}
local config = require("gtodo-md.config")
local logic_mod = require("gtodo-md.logic")
local lock_mod = require("gtodo-md.lock")

-- handle_buf_enter が「自前のdueチェック・ソートを再実行すべきか」を判定するための
-- キャッシュ。init.lua から get_cache()/update_cache() 経由でのみ読み書きされる。
local last_processed_mtimes = {
	inbox = 0,
	todo = 0,
	done = 0,
}

-- #89: mtime(秒精度)だけでは1秒以内の連続変更を見逃すため、ファイルサイズを
-- 補助的な変更検知として併用する。完全な解決(内容ハッシュ化等)は毎回ファイル
-- 全読みのコストが見合わないため見送り、「同一秒内でサイズも同じ変更」という
-- 更に狭いケースは due.lua の R5-3 と同様、低確率として許容する。
local last_processed_sizes = {
	inbox = 0,
	todo = 0,
	done = 0,
}
local last_processed_date = ""

-- 他インスタンスによる外部変更検知(reload_if_externally_changed)専用のキャッシュ。
--
-- 以前は last_processed_mtimes を上の用途と共有していたが、それぞれ更新タイミングが
-- 異なる(前者はcheck_daily_rolloverのたびに、後者はhandle_buf_enterが実際に処理を
-- 終えたときのみ)ため、一方が変化を検知して更新すると、もう一方がその変化を
-- 二度と検知できなくなる不具合があった。具体的には、check_daily_rollover が
-- handle_buf_enter より先に走ってmtime差分を消費してしまうため、
-- 「保存直後にバッファへ入り直しても自前のdueチェック・ソートが実行されない」
-- という形で表面化していた。用途ごとに独立したキャッシュを持つことで解消する。
local external_change_mtimes = {
	inbox = 0,
	todo = 0,
	done = 0,
}

-- キャッシュ取得用アクセサ。
-- #98: テーブルの参照をそのまま返すと、呼び出し側が誤って書き換えた場合に
-- 内部キャッシュが汚染されてしまうため、シャローコピーを返す。
function M.get_cache()
	return vim.tbl_extend("force", {}, last_processed_mtimes),
		last_processed_date,
		vim.tbl_extend("force", {}, last_processed_sizes)
end

-- キャッシュ更新用アクセサ
function M.update_cache(inbox_mtime, todo_mtime, done_mtime, inbox_size, todo_size, done_size)
	local data_dir = config.get("data_dir")
	last_processed_mtimes.inbox = inbox_mtime
	last_processed_mtimes.todo = todo_mtime
	last_processed_mtimes.done = done_mtime or vim.fn.getftime(data_dir .. "/done.md")
	last_processed_sizes.inbox = inbox_size or vim.fn.getfsize(data_dir .. "/inbox.md")
	last_processed_sizes.todo = todo_size or vim.fn.getfsize(data_dir .. "/todo.md")
	last_processed_sizes.done = done_size or vim.fn.getfsize(data_dir .. "/done.md")
	last_processed_date = os.date("%Y-%m-%d")
end

-- プラグイン管理ファイルのバッファに autoread を設定したうえで checktime を実行する。
-- autoread をバッファ単位で設定することで、ユーザーの他ファイルの設定に影響を与えずに
-- 確認ダイアログを抑制できる。グローバルな &autoread を変更しない理由はここにある。
-- init.lua の各 checktime 呼び出し箇所からも参照できるよう公開している。
function M.reload_managed_bufs()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
			local bname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
			if bname == "inbox.md" or bname == "todo.md" or bname == "done.md" then
				vim.bo[buf].autoread = true
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("checktime")
				end)
			end
		end
	end
end

-- mtime ベースの外部変更検知とリロード。
-- 複数インスタンスのうち別インスタンスがロールオーバーを先に実行した場合、
-- このインスタンスは check_daily_rollover を early return するため
-- checktime が走らない。そのギャップを埋めるためにここで mtime を確認する。
local function reload_if_externally_changed()
	local data_dir = config.get("data_dir")
	local paths = {
		inbox = data_dir .. "/inbox.md",
		todo = data_dir .. "/todo.md",
		done = data_dir .. "/done.md",
	}

	local changed = false
	for key, path in pairs(paths) do
		local mtime = vim.fn.getftime(path)
		if mtime ~= external_change_mtimes[key] then
			changed = true
			external_change_mtimes[key] = mtime
		end
	end

	if changed then
		M.reload_managed_bufs()
	end
end

-- 日付変更チェックと自動タスク整理
function M.check_daily_rollover()
	local today = os.date("%Y-%m-%d")
	if last_processed_date ~= "" and today == last_processed_date then
		-- 日付変更なしでも、別インスタンスによる外部変更を検知してリロード
		reload_if_externally_changed()
		return
	end

	local last_opened = require("gtodo-md.utils").read_last_opened()
	if last_opened ~= today then
		local data_dir = config.get("data_dir")
		local inbox_path = data_dir .. "/inbox.md"
		local todo_path = data_dir .. "/todo.md"
		local done_path = data_dir .. "/done.md"

		-- fn の最後でのみ true にすることで、途中でエラーが起きた場合は
		-- rollover_ok が false のままになり、以降の状態更新をスキップして
		-- 次回呼び出しでのリトライを許可できる
		local rollover_ok = false
		local acquired = lock_mod.with_write_lock(data_dir, function()
			local todo_changed = logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)
			if logic_mod.check_dues(inbox_path, todo_path) then
				todo_changed = true
			end
			if todo_changed then
				logic_mod.sort_todo_file(todo_path)
			end
			require("gtodo-md.utils").write_last_opened(today)
			rollover_ok = true
		end)

		if not acquired then
			-- 別インスタンスがロールオーバー実行中(またはロック取得失敗)。
			-- last_processed_date は更新せず、現時点での外部変更チェックを実行して終了する。
			-- 別インスタンスの完了後に次回の呼び出しで last_opened == today 側に分岐して処理される。
			reload_if_externally_changed()
			return
		end

		if not rollover_ok then
			-- エラーは lock_mod 側で通知済み。状態は進めずリトライを許可する。
			return
		end

		-- ロールオーバー完了後の mtime/サイズをキャッシュする。
		-- ロールオーバー自体が dueチェック・ソートを実行済みのため、
		-- handle_buf_enter用・外部変更検知用の両方のキャッシュを更新してよい。
		local new_inbox_mtime = vim.fn.getftime(inbox_path)
		local new_todo_mtime = vim.fn.getftime(todo_path)
		local new_done_mtime = vim.fn.getftime(done_path)
		last_processed_mtimes.inbox = new_inbox_mtime
		last_processed_mtimes.todo = new_todo_mtime
		last_processed_mtimes.done = new_done_mtime
		last_processed_sizes.inbox = vim.fn.getfsize(inbox_path)
		last_processed_sizes.todo = vim.fn.getfsize(todo_path)
		last_processed_sizes.done = vim.fn.getfsize(done_path)
		external_change_mtimes.inbox = new_inbox_mtime
		external_change_mtimes.todo = new_todo_mtime
		external_change_mtimes.done = new_done_mtime
		M.reload_managed_bufs()
		last_processed_date = today
	else
		-- 別インスタンスが先にロールオーバーを実施した可能性があるためチェック
		reload_if_externally_changed()
		last_processed_date = today
	end
end

return M
