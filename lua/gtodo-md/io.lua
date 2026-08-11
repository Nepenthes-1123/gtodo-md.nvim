local M = {}
local task_mod = require("gtodo-md.task")
local config = require("gtodo-md.config")
local uv = vim.uv or vim.loop

-- 指定されたパスのバッファが存在し、ロードされているか確認
local function get_buf_by_name(path)
	local realpath = vim.fn.fnamemodify(path, ":p")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local bufname = vim.api.nvim_buf_get_name(buf)
			if vim.fn.fnamemodify(bufname, ":p") == realpath then
				return buf
			end
		end
	end
	return nil
end

-- 並行更新(lost update)検出用のスタンプ表。
-- key: 正規化した絶対パス, value: { sec, nsec, size }
local read_stamps = {}

local function norm_path(path)
	return vim.fn.fnamemodify(path, ":p")
end

local function stat_stamp(path)
	local st = uv.fs_stat(path)
	if not st then
		return nil
	end
	return { sec = st.mtime.sec, nsec = st.mtime.nsec or 0, size = st.size }
end

-- 「このパスの内容をディスクと同期した」と言える時点の stat を記録する。
--
-- 記録してよい契機は次の4つだけ:
--   1. read_lines がディスクから読んだ直後
--   2. BufReadPost (autocmds.lua から)
--   3. BufWritePost (autocmds.lua から。ユーザーの :w もここで拾う)
--   4. 自身の write_lines が成功した直後
--
-- read_lines がバッファ優先で読んだときに記録してはならない。バッファの内容は
-- 「読んだ瞬間のディスク」ではなく「最後にディスクと同期した時点」の写しであり、
-- そこで今のディスクを刻印すると、古いバッファと新しいディスクを「一致している」と
-- 誤って宣言することになる。その状態で全行置換すると、他インスタンスがその間に
-- 追記した行を検出できないまま消してしまう。
function M.record_stamp(path)
	read_stamps[norm_path(path)] = stat_stamp(path)
end

-- 既に追跡中のパスに限ってスタンプを更新する。
-- 追跡していないパスまで記録すると、プラグインが書かないファイルの分まで
-- 表が際限なく育つため、対象を絞るための入口を分けている。
function M.refresh_stamp_if_tracked(path)
	if read_stamps[norm_path(path)] then
		M.record_stamp(path)
	end
end

-- ディスクの内容が、そのパスのバッファと完全に一致しているかを見る。
--
-- スタンプは「同期点を観測できた」ときしか更新できないが、観測できない同期点が
-- 現実に存在する。最たる例が **autocmd の中で実行される `:write`** で、
-- autocmd は既定でネストしないため `BufWritePost` が発火せず、ディスクだけが
-- 進んでスタンプが取り残される。
--
-- mtime/size が動いていても内容がバッファと一致しているなら、
-- 「こちらが読んだ内容」を書き換えた者はいない。並行更新ではないので通してよい。
-- 逆に内容が違えば、それは本物の並行更新である。
local function disk_matches_buffer(path, buf)
	local f = io.open(path, "r")
	if not f then
		return false
	end
	local disk = {}
	for line in f:lines() do
		if line:sub(-1) == "\r" then
			line = line:sub(1, -2)
		end
		table.insert(disk, line)
	end
	f:close()

	local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if #disk ~= #buf_lines then
		return false
	end
	for i = 1, #disk do
		if disk[i] ~= buf_lines[i] then
			return false
		end
	end
	return true
end

-- 書き込み直前に、読み取り時点からディスクが動いていないかを確認する。
-- 動いていれば、他インスタンス(またはユーザーの :w)が書いた内容を全行置換で
-- 潰すことになるため、一切書かずに中断する。
--
-- これは検出であって防止ではない。stat から rename までの窓に他インスタンスの
-- 書き込みが挟まれば取り逃すし、スタンプが無いパス(read を経ずに書く経路)は
-- 照合そのものを行わない。静かな消失を明示的な失敗に変えるのが目的。
local function assert_not_changed_since_read(path)
	local recorded = read_stamps[norm_path(path)]
	if not recorded then
		return
	end
	local current = stat_stamp(path)
	if not current then
		-- ファイルが存在しない。新規作成として扱い、書き込みを許す。
		return
	end
	if current.sec == recorded.sec and current.nsec == recorded.nsec and current.size == recorded.size then
		return
	end

	-- stat が食い違っていても、内容がバッファと同じなら並行更新ではない
	-- (観測できなかった同期点)。スタンプを回収して書き込みを許す。
	-- バッファが無い場合は比較対象が無いため救済しない — その場合の lines は
	-- ディスクから読んだものであり、ディスクが動いていれば本物の並行更新である。
	local buf = get_buf_by_name(path)
	if buf and disk_matches_buffer(path, buf) then
		read_stamps[norm_path(path)] = current
		return
	end

	error(
		string.format(
			"[gtodo-md] %s は他のプロセスによって更新されています。書き込みを中止しました。\n"
				.. "バッファを再読み込み(:checktime または :e)してから操作をやり直してください。",
			path
		),
		0
	)
end

-- ファイルまたはバッファから行リストを読み込む
function M.read_lines(path)
	local buf = get_buf_by_name(path)
	if buf then
		-- バッファ優先。ここでスタンプを更新しないのが要点(record_stamp のコメント参照)。
		return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	else
		local lines = {}
		local f = io.open(path, "r")
		if not f then
			return lines
		end
		-- 読み始める前に記録する。読んでいる最中に書き換えられた場合も
		-- スタンプが古いままになるため、後続の照合で検出できる。
		M.record_stamp(path)
		for line in f:lines() do
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
			end
			table.insert(lines, line)
		end
		f:close()
		return lines
	end
end

-- 指定ディレクトリ直下の `*.md` を、更新日時(mtime)の降順で拡張子無しの
-- ファイル名一覧として返す。ディレクトリが存在しなければ空配列を返す。
-- テンプレート一覧(ui/template.lua)・プロジェクト一覧(ui/prompt.lua)双方が
-- 同じ「ディレクトリ内のmdを新しい順に列挙する」処理を必要とするための共通ヘルパー。
function M.list_md_basenames_by_mtime(dir)
	local names = {}
	if vim.fn.isdirectory(dir) == 0 then
		return names
	end

	local files = vim.fn.globpath(dir, "*.md", false, true)
	local temp = {}
	for _, file in ipairs(files) do
		local name = vim.fn.fnamemodify(file, ":t:r")
		local mtime = vim.fn.getftime(file)
		table.insert(temp, { name = name, mtime = mtime })
	end
	table.sort(temp, function(a, b)
		return a.mtime > b.mtime
	end)
	for _, item in ipairs(temp) do
		table.insert(names, item.name)
	end
	return names
end

-- 差分のみを更新し、Extmarksの破壊を防ぐ
local function update_lines_incrementally(buf, new_lines)
	local old_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local start_idx = 1
	while start_idx <= #old_lines and start_idx <= #new_lines and old_lines[start_idx] == new_lines[start_idx] do
		start_idx = start_idx + 1
	end

	local end_old = #old_lines
	local end_new = #new_lines
	while end_old >= start_idx and end_new >= start_idx and old_lines[end_old] == new_lines[end_new] do
		end_old = end_old - 1
		end_new = end_new - 1
	end

	if start_idx > #old_lines and start_idx > #new_lines then
		return -- 変更なし
	end

	local replacement = {}
	for i = start_idx, end_new do
		table.insert(replacement, new_lines[i])
	end

	vim.api.nvim_buf_set_lines(buf, start_idx - 1, end_old, false, replacement)
end

-- write_lines の完了後に通知するオブザーバのリスト。
-- io.lua は下位層のため上位層(ui 等)を require してはならず、
-- 「書き込みが起きたこと」を通知する仕組みだけを提供して、
-- 何をするかは購読側(上位層)が M.add_write_observer で登録する。
local write_observers = {}

-- 書き込み後に呼ばれるコールバックを登録する。
-- コールバックは書き込み先の path を引数に受け取る。
-- 解除用のAPIは現時点で必要としていないため用意していない。
function M.add_write_observer(fn)
	table.insert(write_observers, fn)
end

-- オブザーバのエラーが書き込み処理本体(および他のオブザーバ)を
-- 巻き込まないよう、1件ずつ pcall で隔離して呼ぶ。
local function notify_write_observers(path)
	for _, fn in ipairs(write_observers) do
		pcall(fn, path)
	end
end

-- 一時ファイル名に使う連番。<pid> と組み合わせて名前の衝突確率を下げるための
-- ヒントであり、正しさを担保するのは fs_open の "wx"(O_EXCL) である。
-- PID は OS に再利用されるため所有者の識別子として使ってはならない
-- (残骸の掃除が mtime だけで判定しているのはこのため)。
local tmp_seq = 0

-- 残骸とみなすまでの猶予。write_lines は open→write→fsync→rename を同期実行するため、
-- 一時ファイルの寿命は通常ミリ秒〜数十ミリ秒しかない。ここを短く取ると、I/O が
-- ストールした他インスタンスの「書き込み途中」のファイルを消してしまう。
-- lock.lua の STALE_SECONDS とは守る対象が違うので値を揃えない。
local TMP_TTL_SECONDS = 24 * 60 * 60

-- rename が一時的な共有違反で弾かれたときの再試行間隔(ミリ秒、総待機 630ms)。
-- Windows では他インスタンスが checktime のためにファイルハンドルを保持している間、
-- MoveFileExW が ERROR_ACCESS_DENIED / ERROR_SHARING_VIOLATION で失敗しうる。
-- この予算は正しさを支えるものではなく失敗頻度を下げるだけで、実測に基づく値でもない。
local RENAME_BACKOFF_MS = { 10, 20, 40, 80, 160, 320 }

-- 再試行して結果が変わりうるエラーだけを対象にする。ENOSPC や EXDEV は何度試しても
-- 同じなので、待つだけ無駄(かつ UI を止める)ため即座に失敗させる。
local RETRYABLE_RENAME_ERRORS = { EACCES = true, EBUSY = true, EPERM = true }

-- luv はバージョンによって (nil, msg) と (nil, msg, code) の両方を返しうるため、
-- どちらの形でもエラーコードを取り出せるようにする。
local function err_code(msg, code)
	if code then
		return code
	end
	return tostring(msg or ""):match("^(E%u+)") or ""
end

-- シンボリックリンクは実体パスへ解決してから書き込む。リンクをそのまま rename の
-- 置換先にすると、リンク自体が実体ファイルで置き換わって消え、ユーザーが構築した
-- 外部同期や共有の仕組みが警告なく壊れる。実体側のディレクトリに一時ファイルを
-- 作るため、実体が別ファイルシステムにあっても rename は同一FS内で完結する。
local function resolve_link(path)
	local lst = uv.fs_lstat(path)
	if not lst or lst.type ~= "link" then
		return path
	end
	return uv.fs_realpath(path) or path
end

-- 一時ファイルを O_EXCL で作る。名前が衝突しても既存ファイルを壊さず EEXIST で
-- 失敗するので、連番を進めて数回だけやり直す。
local function create_tmp(dir, base)
	for _ = 1, 3 do
		tmp_seq = tmp_seq + 1
		local tmp_path = string.format("%s/.%s.%d.%d.tmp", dir, base, vim.fn.getpid(), tmp_seq)
		local fd, msg, code = uv.fs_open(tmp_path, "wx", 384) -- 0600
		if fd then
			return fd, tmp_path
		end
		if err_code(msg, code) ~= "EEXIST" then
			return nil, nil, msg
		end
	end
	return nil, nil, "temporary file name kept colliding"
end

-- 内容を書き切ってから fsync する。fsync を挟まないと、ファイルシステムによっては
-- rename のメタデータだけが先に永続化され、直後のクラッシュで「中身が0バイトの
-- ファイル」が残る。todo データの唯一の保管先なのでこの失敗モードは許容しない。
local function write_and_sync(fd, data)
	local offset = 0
	while offset < #data do
		local written, msg = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written then
			return nil, msg
		end
		offset = offset + written
	end
	local synced, sync_err = uv.fs_fsync(fd)
	if not synced then
		return nil, sync_err
	end
	return true
end

-- 既存ファイルの権限を一時ファイルへ引き継ぐ。"wx" は 0600 で作るため、これをせずに
-- rename すると 0644 のファイルが 0600 へ静かに落ちる。
-- stat が失敗したときは「ファイルが無い(＝新規作成)」のか「一時的に stat できない
-- (EMFILE 等)」のかを区別する。後者を新規作成と同じ扱いにすると、既存ファイルの
-- 権限を落としたまま確定させてしまうため、書き込み自体を失敗させる。
local function inherit_mode(target, tmp_path)
	local st, msg, code = uv.fs_stat(target)
	if st then
		uv.fs_chmod(tmp_path, st.mode)
		return true
	end
	if err_code(msg, code) == "ENOENT" then
		return true
	end
	return nil, msg
end

local function rename_with_retry(tmp_path, target)
	local ok, msg, code = uv.fs_rename(tmp_path, target)
	local attempt = 0
	while not ok and attempt < #RENAME_BACKOFF_MS and RETRYABLE_RENAME_ERRORS[err_code(msg, code)] do
		attempt = attempt + 1
		-- vim.wait はイベントループを回すため、書き込みの途中で他の autocmd や
		-- ユーザー操作が再入する。ここはスレッドごと止める uv.sleep を使う。
		uv.sleep(RENAME_BACKOFF_MS[attempt])
		ok, msg, code = uv.fs_rename(tmp_path, target)
	end
	if not ok then
		return nil, msg
	end
	return true
end

-- ファイルの内容をアトミックに置き換える。成功なら true、失敗なら nil とエラー文字列。
--
-- vim.fn.rename() は使わない。Neovim の vim_rename() は rename の前に
-- os_remove(to) で置換先を削除するため、置換先が一瞬ディスクから消える。
-- 同じ data_dir を複数インスタンスが共有する運用ではこの窓を他インスタンスが踏み、
-- 読み取りが空を返す・checktime が壊れた状態を拾う、といった事故につながる(#125)。
-- uv.fs_rename は置換先を消さずに差し替える(POSIX: rename(2)、Windows:
-- MoveFileExW の MOVEFILE_REPLACE_EXISTING)。
-- 書こうとしている内容が、既にディスク上にあるものと1バイト違わないかを見る。
-- サイズが違えば読むまでもないので stat で足切りする。
local function content_unchanged(target, data)
	local st = uv.fs_stat(target)
	if not st or st.size ~= #data then
		return false
	end
	local f = io.open(target, "rb")
	if not f then
		return false
	end
	local current = f:read("*a")
	f:close()
	return current == data
end

local function atomic_replace(path, data)
	local target = resolve_link(path)

	-- 内容が変わらないなら書かない。
	-- 書けば mtime が動き、同じ data_dir を開いている全インスタンスが checktime で
	-- リロードする。自動処理(sort_todo_file 等)は結果が同じでも毎回書きに来るため、
	-- ここで止めないと「何も変わっていないのに全インスタンスが一斉にリロードする」
	-- 状態が定期的に発生し、リロードに伴う副作用(未保存編集の破棄・スタンプのずれ・
	-- rename の窓)を無意味に踏み続けることになる。
	if content_unchanged(target, data) then
		return true
	end

	local dir = vim.fn.fnamemodify(target, ":h")
	local base = vim.fn.fnamemodify(target, ":t")

	-- 一時ファイルは必ず置換先と同じディレクトリに作る。別ディレクトリだと
	-- クロスデバイス rename になり EXDEV で失敗する。
	local fd, tmp_path, open_err = create_tmp(dir, base)
	if not fd then
		return nil, string.format("open: %s", tostring(open_err))
	end

	local written, write_err = write_and_sync(fd, data)
	uv.fs_close(fd)
	if not written then
		uv.fs_unlink(tmp_path)
		return nil, string.format("write: %s", tostring(write_err))
	end

	local mode_ok, mode_err = inherit_mode(target, tmp_path)
	if not mode_ok then
		uv.fs_unlink(tmp_path)
		return nil, string.format("stat: %s", tostring(mode_err))
	end

	local renamed, rename_err = rename_with_retry(tmp_path, target)
	if not renamed then
		uv.fs_unlink(tmp_path)
		return nil, string.format("rename: %s", tostring(rename_err))
	end

	return true
end

-- 行リストを指定の改行コードでアトミックに書き出す。
local function write_lines_to_disk(path, lines, use_crlf)
	local nl = use_crlf and "\r\n" or "\n"
	local data = #lines > 0 and (table.concat(lines, nl) .. nl) or ""
	return atomic_replace(path, data)
end

-- 任意の内容をアトミックに書き出す公開ヘルパー。
-- markdown 以外(.state.json、projects/*.md のテンプレート)を書く上位層が、
-- 同じ置換手順を各自で実装し直さずに済むよう io.lua 側に集約する。
-- 成功なら true、失敗なら nil とエラー文字列を返す(error は投げない —
-- 呼び出し元の失敗時の振る舞いがそれぞれ異なるため判断を委ねる)。
function M.atomic_write(path, data)
	return atomic_replace(path, data)
end

-- 残留した一時ファイルを掃除する。判定は mtime だけで行い、ファイル名に含まれる
-- PID は見ない。PID は OS に再利用されるため所有者の識別子にならず、再利用された
-- 瞬間にその残骸がどのインスタンスからも永久に削除対象から外れてしまう。
-- 削除できなかった場合は放置する(他インスタンスが同時に消した場合など)。
local function sweep_stale_tmp(dir)
	local scanner = uv.fs_scandir(dir)
	if not scanner then
		return
	end
	local now = os.time()
	while true do
		local name, entry_type = uv.fs_scandir_next(scanner)
		if not name then
			break
		end
		if entry_type ~= "directory" and name:match("^%..+%.tmp$") then
			local entry_path = dir .. "/" .. name
			local st = uv.fs_stat(entry_path)
			if st and (now - st.mtime.sec) > TMP_TTL_SECONDS then
				uv.fs_unlink(entry_path)
			end
		end
	end
end

-- バッファが無い場合の改行コード判定。既存ファイルの先頭だけ覗いて CRLF かを見る。
local function detect_crlf(path)
	if vim.fn.filereadable(path) == 0 then
		return false
	end
	local fr = io.open(path, "rb")
	if not fr then
		return false
	end
	local content = fr:read(2048) or ""
	fr:close()
	return content:find("\r\n") ~= nil
end

-- ファイルまたはバッファに行リストを書き込む。
--
-- バッファが開いている場合でも nvim_buf_call + :write は使わない。
-- カレントバッファを一瞬切り替えることによる画面のちらつき(#57)や、
-- BufWritePre 等の意図しないautocmd発火(検証の誤発火・処理の多重発火)を
-- 避けるため、バッファへは直接内容を反映して modified フラグをクリアするに
-- 留め、ディスクへは別途アトミックに置き換える(一時ファイルへ書いて fsync し、
-- uv.fs_rename で差し替える)。
--
-- バッファが未保存(dirty)であっても常に反映・保存する。read_lines が
-- ライブバッファの内容(未保存分を含む)を読み取った上でこの関数に渡される
-- 想定のため、自動処理による変更とユーザーの未保存編集はマージされて保存される。
-- ただしこれが成立するのは「読んでから書くまでの間にディスクが動いていない」
-- 場合に限る。他インスタンスや外部ツールが先にディスクを書いていた場合、
-- autocmds.lua の FileChangedShell がバッファをディスクの内容へ強制リロードするため、
-- そこで未保存編集は破棄される(バッファ内 undo で復旧可)。
--
-- ディスクへの書き込みが失敗した場合は error を投げる。以前は失敗を黙殺していたが、
-- 呼び出し元が成功と信じたまま処理を続けるため、何が失われたのか誰にも分からなかった。
function M.write_lines(path, lines)
	local buf = get_buf_by_name(path)
	local use_crlf
	if buf then
		use_crlf = vim.bo[buf].fileformat == "dos"
	else
		use_crlf = detect_crlf(path)
	end

	-- 読み取り時点からディスクが動いていれば、ここで中断する(全行置換のため、
	-- 続行すると他インスタンスの変更を黙って潰すことになる)。
	assert_not_changed_since_read(path)

	-- ディスクへの書き込みを先に確定させる。バッファを先に更新して modified を
	-- 落とすと、ディスク書き込みが失敗したときバッファだけが「保存済み」に見え、
	-- 次の checktime で古い内容へ静かに戻ってユーザーの変更が消える。
	local ok, err = write_lines_to_disk(path, lines, use_crlf)
	if not ok then
		error(string.format("[gtodo-md] failed to write %s: %s", path, err), 0)
	end

	-- 自分が書いた結果を新しい基準にする(次回の照合で自分の書き込みを
	-- 他インスタンスの変更と誤検出しないため)。
	M.record_stamp(path)

	if buf then
		update_lines_incrementally(buf, lines)
		if vim.bo[buf].modified then
			vim.bo[buf].modified = false
		end

		-- :write を使わずディスクへ直接書き込んだため、Vimが内部で持つ
		-- 「最後に確認したファイルの更新時刻」がこの書き込みを認識しないまま
		-- 古い値で残ってしまう。これを放置すると、後で別の編集が加わった際に
		-- Vimが(実際にはこのプラグイン自身が書いた)今回の変更を「外部での
		-- 変更」と誤認し、W12/W13警告を誤って出してしまう。バッファは既に
		-- クリーンな状態のため、この checktime は(内容が同じディスクを読み直す
		-- だけで)画面上は何も起きずに完了する。バッファ番号を明示指定するため
		-- カレントバッファの切り替えも発生しない。
		--
		-- #125: ただし、この書き込みと直前の読み取りの間に他インスタンスが
		-- 割り込んでいた場合は実際にリロードが起き、'undofile' が有効なら
		-- Neovim が undo ファイルを書きに行く。undo ファイルはプロセス間で
		-- ロックされないため、そこで E828 になりうる。自分が撃つ checktime の
		-- 間だけ無効化して元に戻す。
		--
		-- io.lua は最下層で utils.is_gtodo_file を require できない(階層制約)。
		-- 管理対象かどうかを判定できない以上、恒久的に落とすと管理外ファイルの
		-- 永続 undo まで黙って壊すことになるため、退避・復元に留める。
		-- 管理対象バッファを恒久的に無効化するのは autocmds.lua の責務。
		local saved_undofile = vim.bo[buf].undofile
		vim.bo[buf].undofile = false
		pcall(vim.cmd, "silent! checktime " .. buf)
		vim.bo[buf].undofile = saved_undofile
	end

	notify_write_observers(path)
end

-- 指定ファイルをパースして、セクションごとの行のリストにする
function M.read_todo_file(filepath)
	local lines = M.read_lines(filepath)
	if #lines == 0 then
		return { sections = {}, section_order = {}, header = {} }
	end
	return M.parse_markdown(lines)
end

-- #94: 見出しが config.section_aliases(key) に含まれる名前(デフォルト名/
-- 前回の設定名)であれば、その場で現在のカスタム名へ正規化する。これにより
-- due.lua等の既存の config.sections.* 参照箇所は一切変更せずに動作し続け、
-- 既存ファイルの見出しをユーザーに手動でリネームさせる必要もない
-- (次回保存時に write_todo_file が新しい名前で書き戻す)。
local function normalize_section_name(name)
	for key, _ in pairs(config.default_sections) do
		for _, alias in ipairs(config.section_aliases(key)) do
			if name == alias then
				return config.sections[key]
			end
		end
	end
	return name
end

function M.parse_markdown(lines)
	local data = {
		header = {},
		sections = {},
		section_order = {},
	}

	local current_section = "default"
	data.sections[current_section] = {}

	local header_done = false

	for _, line in ipairs(lines) do
		-- ## セクション境界
		local sec_name = line:match("^##%s+(.*)$")
		local task = task_mod.parse(line)

		if sec_name then
			sec_name = normalize_section_name(vim.trim(sec_name))
			current_section = sec_name
			if not data.sections[current_section] then
				data.sections[current_section] = {}
				table.insert(data.section_order, current_section)
			end
			header_done = true
		elseif task then
			header_done = true
		end

		if not header_done then
			table.insert(data.header, line)
		elseif not sec_name then
			local target_items = data.sections[current_section]

			if task then
				table.insert(target_items, { type = "task", task = task, line = line })
			else
				-- 空行はソート時のインデックスズレやMarkdownリスト分断の原因になるため無視する
				-- ### 見出し等の非タスク行はそのまま type="text" として保持し、
				-- 元の位置に書き戻す（sort.lua が並び替えの境界として扱う）。
				if vim.trim(line) ~= "" then
					table.insert(target_items, { type = "text", line = line })
				end
			end
		end
	end

	return data
end

-- items リスト（task/text のフラット配列）を行リストに変換するローカルヘルパー
-- seen_ids: この write_todo_file 呼び出し全体(全セクション・全サブセクション)で
-- 使用済みのIDを追跡する共有テーブル。コピー&ペーストで複製されたタスクが
-- 同じIDを持ち続けないよう、既に登場済みのIDを持つタスクは再発行させる
-- (ファイル内で最初に登場した方が元のIDを保持する)。
local function items_to_lines(items, lines, seen_ids)
	for _, item in ipairs(items) do
		if item.type == "task" then
			if item.task.id and item.task.id ~= "" and seen_ids[item.task.id] then
				item.task.id = nil -- 重複しているので serialize に再発行させる
			end
			local line = task_mod.serialize(item.task)
			seen_ids[item.task.id] = true
			table.insert(lines, line)
		else
			local text = item.line
			if vim.trim(text) == "" then
				if #lines > 0 and vim.trim(lines[#lines]) ~= "" then
					table.insert(lines, text)
				end
			else
				-- 見出し行(### 等)は前後に空行を入れる。markdownlint 等の
				-- 一般的な整形規約(見出しは空行で囲む)に沿わせるための処理で、
				-- サブセクションを構造化データとして特別扱いしているわけではない
				-- (## セクション見出し自体は data.header 側で別途処理される)。
				local is_heading = text:match("^#+%s") ~= nil
				if is_heading and #lines > 0 and lines[#lines] ~= "" then
					table.insert(lines, "")
				end
				table.insert(lines, text)
				if is_heading then
					table.insert(lines, "")
				end
			end
		end
	end
end

-- 連続する空行を1行に圧縮する(markdownlint MD012対策)。
-- data.header はユーザーが書いた行をそのまま echo するだけで空行を
-- フィルタしないため(セクション内の items とは異なり)、手編集等で
-- 見出し前に空行が連続していると、そのままファイルに残り続けていた。
local function collapse_blank_runs(lines)
	local result = {}
	for _, line in ipairs(lines) do
		-- 直前が既に空行なら追加しない(圧縮)
		local is_redundant_blank = vim.trim(line) == "" and #result > 0 and vim.trim(result[#result]) == ""
		if not is_redundant_blank then
			table.insert(result, line)
		end
	end
	return result
end

-- パースしたデータを書き戻す
function M.write_todo_file(filepath, data)
	local lines = {}
	-- このファイル書き出し全体を通してIDの重複を検知するための共有テーブル
	local seen_ids = {}

	for _, l in ipairs(data.header) do
		table.insert(lines, l)
	end

	-- default セクション（## なし領域）の書き出し
	local default_items = data.sections["default"] or {}
	if #default_items > 0 then
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		items_to_lines(default_items, lines, seen_ids)
	end

	for _, sec in ipairs(data.section_order) do
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		table.insert(lines, "## " .. sec)
		table.insert(lines, "")

		items_to_lines(data.sections[sec] or {}, lines, seen_ids)
	end

	lines = collapse_blank_runs(lines)

	-- 末尾の空行は取り除く。write_lines_to_disk が各行の後ろに改行を付けて
	-- 書き出すため、最終行の改行だけでファイルは正しく改行で終わる。
	-- ここで空文字列の行を足すと、その分の改行が最終行の改行に続いて
	-- ファイル末尾が "\n\n" になり、:w のたびに末尾の空行が1行増えていた
	-- (markdownlint MD012)。
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end

	M.write_lines(filepath, lines)
	return true
end

function M.ensure_files()
	local data_dir = config.get("data_dir")
	local files = {
		{ path = data_dir .. "/inbox.md", title = "# Inbox\n" },
		{
			path = data_dir .. "/todo.md",
			title = "# Todo\n\n## " .. table.concat(
				vim.tbl_map(function(key)
					return config.sections[key]
				end, config.section_order),
				"\n\n## "
			),
		},
		{ path = data_dir .. "/done.md", title = "# Done\n" },
		{ path = data_dir .. "/cancelled.md", title = "# Cancelled\n" },
	}

	for _, f in ipairs(files) do
		if vim.fn.filereadable(f.path) == 0 then
			-- 作成失敗を握り潰すと、以降の読み取りが「空ファイル」と区別できないまま
			-- 進み、原因の分からない不具合として表面化する。1件ずつ通知して続行する
			-- (1つ失敗しても他のファイルは作れる可能性があるため中断はしない)。
			local ok, err = atomic_replace(f.path, f.title .. "\n")
			if not ok then
				vim.notify(
					string.format("[gtodo-md] failed to create %s: %s", f.path, tostring(err)),
					vim.log.levels.ERROR
				)
			end
		end
	end

	-- クラッシュや書き込み失敗で取り残された一時ファイルを回収する。
	sweep_stale_tmp(data_dir)
	sweep_stale_tmp(data_dir .. "/projects")
end

return M
