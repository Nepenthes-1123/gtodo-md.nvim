local M = {}
local uv = vim.uv or vim.loop

-- クラッシュ等でロックが残留した場合の安全弁として無効化するまでの秒数
local STALE_SECONDS = 60

-- 排他ロックを取得する。
-- libuv の "wx" フラグ（O_WRONLY|O_CREAT|O_EXCL 相当）は、
-- ファイルの存在確認と作成をカーネルレベルでアトミックに行う。
-- これにより複数インスタンスが同時に取得を試みる競合を防ぐ。
-- 動作: Linux/macOS = open(2) の O_EXCL、Windows = CreateFileW の CREATE_NEW
-- ネットワークFS（NFS/SMB等）ではアトミック性が保証されないため非対応。
local function try_acquire(lock_path)
	local fd = uv.fs_open(lock_path, "wx", 384) -- 0o600
	if not fd then
		return false
	end
	-- PID を書き込んでおくことでデバッグ時に保持インスタンスを特定しやすくする
	uv.fs_write(fd, tostring(vim.fn.getpid()), 0)
	uv.fs_close(fd)
	return true
end

local function release(lock_path)
	uv.fs_unlink(lock_path)
end

-- クラッシュ等でロックが残留した場合の安全弁。
-- STALE_SECONDS を超えて存在するロックは、保持プロセスが終了したとみなして強制削除する。
local function cleanup_stale(lock_path)
	local stat = uv.fs_stat(lock_path)
	if stat and (os.time() - stat.mtime.sec) > STALE_SECONDS then
		uv.fs_unlink(lock_path)
	end
end

-- 自動処理全般(dueチェック・ソート・日次ロールオーバー等)で共有する排他ロック。
-- 複数のNeovimインスタンスが同時に書き込みを行わないよう、data_dir 単位で
-- ロックファイル1本を共有する。
--
-- 取得できなかった場合は何もせず false を返す(待機・リトライはしない。
-- 別インスタンスが処理中とみなし、今回は諦めて次回のトリガーに委ねる)。
-- 取得できた場合は fn() を実行し、成否に関わらずロックを解放したうえで true を返す。
-- fn() の実行中にエラーが発生した場合は通知したうえで揉み消す(呼び出し元には伝播しない)。
function M.with_write_lock(data_dir, fn)
	local lock_path = data_dir .. "/.gtodo.lock"
	cleanup_stale(lock_path)

	if not try_acquire(lock_path) then
		return false
	end

	local ok, err = pcall(fn)
	release(lock_path)

	if not ok then
		vim.notify("[gtodo-md] Automatic processing failed: " .. tostring(err), vim.log.levels.ERROR)
	end

	return true
end

return M
