local M = {}
local uv = vim.uv or vim.loop

-- 追記側の rename と削除側の rename の間で、ディレクトリエントリを永続化する。
--
-- 2 回の rename がどの順で永続化されるかはファイルシステム任せである。
-- 削除側だけが先に永続化された状態でクラッシュすると、タスクは追記先にも
-- 削除元にも存在しない = 消失になる。段間で 1 回 fsync することでこの順序を固定する。
-- 対象 2 ファイルは同じ data_dir にあるため 1 回で足りる。
--
-- Windows にはディレクトリの fsync に相当する手段が無い
-- (ディレクトリハンドルへの FlushFileBuffers はサポートされない)ためスキップする。
-- つまり **Windows では 2 回の rename の永続化順序は保証されない**。
-- 書けない保証を書いたことにはしない。
--
-- 失敗しても操作は続行する(同時にクラッシュが起きない限り無害なため)。
local function sync_dir_entries(dir)
	if uv.os_uname().sysname == "Windows_NT" then
		return
	end
	local fd = uv.fs_open(dir, "r", 448) -- 0700
	if not fd then
		return
	end
	pcall(uv.fs_fsync, fd)
	uv.fs_close(fd)
end

-- 2 ファイルにまたがる「移動」を、順序を固定して実行する。
--
-- 単一ディレクトリ内で 2 ファイルを同時にアトミック置換する手段は POSIX / Win32 の
-- いずれにも無い。したがって部分失敗そのものは消せない。
-- **消せないなら、失敗の向きを制御する。**
--
-- 追記(append)を先に、削除(remove)を後に行う:
--   - 前段が失敗した場合: 何も確定していない。例外がそのまま伝播し、削除元は触られない
--   - 後段が失敗した場合: 残留状態は「追記先と削除元の両方に存在 = 重複」
--
-- 消失は復旧不能だが、重複はユーザーが目視でき手で消せる。この非対称性に基づく判断。
-- 逆順(削除が先)だと、後段の失敗でタスクがどちらのファイルからも消える。
--
-- 順序を呼び出し元の記述順に委ねると将来のリファクタで容易に壊れるため、ここで固定する。
-- 呼び出し元は append_fn / remove_fn を渡すだけで、順序と段間の同期に関与しない。
--
-- 重複の自動検出・自動修復は行わない。復旧は手動手順に委ねる。
function M.append_then_remove(append_fn, remove_fn, sync_dir)
	append_fn()

	if sync_dir then
		sync_dir_entries(sync_dir)
	end

	remove_fn()
end

-- テスト用に公開する(POSIX でのみ意味を持つ)
M._sync_dir_entries = sync_dir_entries

return M
