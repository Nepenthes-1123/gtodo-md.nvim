local M = {}
local config = require("gtodo-md.config")
local logic_mod = require("gtodo-md.logic")
local lock_mod = require("gtodo-md.lock")

-- 自動処理のキャッシュ用変数
local last_processed_mtimes = {
	inbox = 0,
	todo = 0,
	done = 0,
}
local last_processed_date = ""

-- キャッシュ取得用アクセサ
function M.get_cache()
	return last_processed_mtimes, last_processed_date
end

-- キャッシュ更新用アクセサ
function M.update_cache(inbox_mtime, todo_mtime, done_mtime)
	last_processed_mtimes.inbox = inbox_mtime
	last_processed_mtimes.todo = todo_mtime
	last_processed_mtimes.done = done_mtime or vim.fn.getftime(config.get("data_dir") .. "/done.md")
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
		if mtime ~= last_processed_mtimes[key] then
			changed = true
			last_processed_mtimes[key] = mtime
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

		-- ロールオーバー完了後の mtime をキャッシュ（次回以降の外部変更検知の基準値）
		last_processed_mtimes.inbox = vim.fn.getftime(inbox_path)
		last_processed_mtimes.todo = vim.fn.getftime(todo_path)
		last_processed_mtimes.done = vim.fn.getftime(done_path)
		M.reload_managed_bufs()
		last_processed_date = today
	else
		-- 別インスタンスが先にロールオーバーを実施した可能性があるためチェック
		reload_if_externally_changed()
		last_processed_date = today
	end
end

return M
