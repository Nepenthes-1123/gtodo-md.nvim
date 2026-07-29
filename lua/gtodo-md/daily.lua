local M = {}
local config = require("gtodo-md.config")
local logic_mod = require("gtodo-md.logic")
local uv = vim.uv or vim.loop

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
function M.update_cache(inbox_mtime, todo_mtime)
	last_processed_mtimes.inbox = inbox_mtime
	last_processed_mtimes.todo = todo_mtime
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

-- ロールオーバーの排他ロックを取得する。
-- libuv の "wx" フラグ（O_WRONLY|O_CREAT|O_EXCL 相当）は、
-- ファイルの存在確認と作成をカーネルレベルでアトミックに行う。
-- これにより複数インスタンスが同時にロールオーバーを実行する競合を防ぐ。
-- 動作: Linux/macOS = open(2) の O_EXCL、Windows = CreateFileW の CREATE_NEW
-- ネットワークFS（NFS/SMB等）ではアトミック性が保証されないため非対応。
-- 返り値: ロック取得成功なら true、既に別インスタンスが保持中なら false
local function try_acquire_rollover_lock(lock_path)
	local fd = uv.fs_open(lock_path, "wx", 384) -- 0o600
	if not fd then
		return false
	end
	-- PID を書き込んでおくことでデバッグ時に保持インスタンスを特定しやすくする
	uv.fs_write(fd, tostring(vim.fn.getpid()), 0)
	uv.fs_close(fd)
	return true
end

-- ロックを解放する
local function release_rollover_lock(lock_path)
	uv.fs_unlink(lock_path)
end

-- クラッシュ等でロックが残留した場合の安全弁。
-- 60秒を超えて存在するロックは、保持プロセスが終了したとみなして強制削除する。
-- 通常のロールオーバーは数十ms で完了するため 60秒はこの判定に十分な余裕がある。
local function cleanup_stale_lock(lock_path)
	local stat = uv.fs_stat(lock_path)
	if stat and (os.time() - stat.mtime.sec) > 60 then
		uv.fs_unlink(lock_path)
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
		local lock_path = data_dir .. "/.rollover.lock"

		-- 残留ロックを掃除してから取得を試みる
		cleanup_stale_lock(lock_path)

		if not try_acquire_rollover_lock(lock_path) then
			-- 別インスタンスがロールオーバー実行中。
			-- last_processed_date を今日に設定し、以後の early return 内の
			-- reload_if_externally_changed() による変更検知に任せる。
			last_processed_date = today
			return
		end

		-- ロック取得成功 → ロールオーバーを実行する。
		-- pcall でラップし、エラー発生時もロック解放を保証する（finally 相当）。
		local ok = pcall(function()
			local todo_changed = logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)
			if logic_mod.check_dues(inbox_path, todo_path) then
				todo_changed = true
			end
			if todo_changed then
				logic_mod.sort_todo_file(todo_path)
			end
			require("gtodo-md.utils").write_last_opened(today)
		end)

		release_rollover_lock(lock_path)

		if ok then
			-- ロールオーバー完了後の mtime をキャッシュ（次回以降の外部変更検知の基準値）
			last_processed_mtimes.inbox = vim.fn.getftime(inbox_path)
			last_processed_mtimes.todo = vim.fn.getftime(todo_path)
			last_processed_mtimes.done = vim.fn.getftime(done_path)
			M.reload_managed_bufs()
		end
	else
		-- 別インスタンスが先にロールオーバーを実施した可能性があるためチェック
		reload_if_externally_changed()
	end

	last_processed_date = today
end

return M
