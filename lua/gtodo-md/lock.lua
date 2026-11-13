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
--
-- 中身は取ったプロセスを見分ける印(プロセス ID と取得した時刻のナノ秒)で、解放するときに
-- 自分のロックかを確かめるのに使う。プロセス ID だけでは、コンテナや WSL と Windows のように
-- ID の空間が別のプロセスと一致しうる。CLI/TUI (gtodo) も同じ形で書く。
-- 取得できれば印を、できなければ nil を返す。
local function owner_token()
	local now = uv.clock_gettime("realtime")
	return string.format("%d %d%09d", vim.fn.getpid(), now.sec, now.nsec)
end

local function try_acquire(lock_path)
	local fd = uv.fs_open(lock_path, "wx", 384) -- 0o600
	if not fd then
		return nil
	end
	local token = owner_token()
	local written = uv.fs_write(fd, token, 0)
	uv.fs_close(fd)
	if written ~= #token then
		-- 印を書けなかったロックは、解放するときに自分のものと確かめられない。
		-- 残すと 60 秒間すべての自動処理が止まるので、取れなかったことにする。
		uv.fs_unlink(lock_path)
		return nil
	end
	return token
end

local function read_file(path)
	local fd = uv.fs_open(path, "r", 384)
	if not fd then
		return nil
	end
	local content = uv.fs_read(fd, 4096, 0)
	uv.fs_close(fd)
	return content
end

-- 自分のロックである場合だけ消す。
--
-- 確かめずに消してはならない。持っている間に 60 秒を超え、他のプロセスが残骸とみなして
-- 取り直していた場合、その相手のロックを消して排他を崩す。確かめてから消すまでの間に
-- 取り直されることは防げない(CLI も同じ)。
local function release(lock_path, token)
	local content = read_file(lock_path)
	if content == token then
		uv.fs_unlink(lock_path)
	elseif content ~= nil then
		vim.notify(
			string.format(
				"[gtodo-md] %s was taken over by another process (held for more than %d seconds); left it in place",
				lock_path,
				STALE_SECONDS
			),
			vim.log.levels.WARN
		)
	else
		-- 消されていた。他のプロセスが残骸とみなして消したので、持っている間の排他は崩れていた
		-- 可能性がある(CLI も同じく知らせる)。
		vim.notify(
			string.format(
				"[gtodo-md] %s was removed by another process (held for more than %d seconds)",
				lock_path,
				STALE_SECONDS
			),
			vim.log.levels.WARN
		)
	end
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
--
-- fn の実行前に必ず reload_managed_bufs() を通す。自動処理は io.read_lines 経由で
-- 「ディスクよりバッファを優先して」読むため、他インスタンスが書いた後で古いバッファを
-- 読むと、全行置換でその変更を潰す。ロックは自分以外の自動処理しか止められず、
-- 他インスタンスのユーザー操作(editor.lua)・:w・Neovim 以外の書き手(同期ツール、
-- git pull)は素通りするので、「書く者を1つに絞る」方向では塞がらない。
-- 読む直前にディスクを取り込んで、古いバッファを読むこと自体を無くす。
-- 呼び出し元ごとに書くと将来の追加経路で漏れるため、ロックの中へ閉じ込めてある。
function M.with_automation_lock(data_dir, fn)
	local lock_path = data_dir .. "/.gtodo.lock"
	cleanup_stale(lock_path)

	local token = try_acquire(lock_path)
	if not token then
		return false
	end

	-- release は pcall の内側に置かないこと。fn が error を投げたときにロックが
	-- 残ると、取得失敗時は即諦める仕様(上記)と相まって、stale 判定される 60 秒間
	-- 全インスタンスの自動処理が通知も無くスキップされる。書き込み失敗が続く状況
	-- (ディスク満杯等)では自動処理が恒常的に間引かれ、日次ロールオーバーを取りこぼす。
	-- 事前リロードも同じ pcall の内側に置く(外へ出すと、そこで例外が出た場合に
	-- ロックが解放されないため)。
	local ok, err = pcall(function()
		-- daily は lock を require しているため、循環参照を避けて呼び出し時に遅延requireする。
		require("gtodo-md.daily").reload_managed_bufs()
		fn()
	end)
	release(lock_path, token)

	if not ok then
		vim.notify("[gtodo-md] Automatic processing failed: " .. tostring(err), vim.log.levels.ERROR)
	end

	return true
end

return M
