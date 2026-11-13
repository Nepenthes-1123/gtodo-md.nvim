-- data_dir/.state.json の読み書き。日次ロールオーバーのゲート(last_opened)、
-- セクション名カスタマイズの前回名記憶(last_sections)、due通知のクールダウン
-- 状態(last_notify_*)といった、アプリケーション状態の永続化を一手に引き受ける。
local M = {}

local function get_state_path()
	local config = require("gtodo-md.config")
	local data_dir = config.get("data_dir")
	return data_dir .. "/.state.json"
end

-- 読んだ内容を返す。ファイルが無い・空なら空のテーブル。
-- 壊れていれば、空のテーブルと理由を返す(読む側は空として処理を続けてよい)。
local function read_state()
	local path = get_state_path()
	local f = io.open(path, "rb")
	if not f then
		return {}
	end
	local content = f:read("*all")
	f:close()
	if not content or vim.trim(content) == "" then
		return {}
	end
	local ok, data = pcall(vim.json.decode, content)
	if not ok then
		return {}, tostring(data)
	end
	-- 空のテーブルは vim.json.encode が "[]" と書くので、空の状態として読む。
	if type(data) ~= "table" or (next(data) ~= nil and vim.islist(data)) then
		return {}, "top level is not an object"
	end
	return data
end

-- 壊れていると通知済みのパス。setup() のたび・期日通知のたびに書きに来るため、
-- 毎回通知すると止まらない。書けたら消して、また壊れたときに通知し直す。
local reported_broken = {}

local function write_state(data)
	local path = get_state_path()
	local dir = vim.fn.fnamemodify(path, ":h")
	-- mkdir() は失敗時に 0 を返すほか、パス上に同名のファイルがある等では
	-- E739 を投げる。素通しにすると `setup()` の途中で例外が飛び、プラグイン全体の
	-- 初期化がそこで止まる(しかもユーザーには原因が読み取れない)。
	if not require("gtodo-md.utils").ensure_dir(dir) then
		vim.notify(string.format("[gtodo-md] failed to create data directory: %s", dir), vim.log.levels.ERROR)
		return
	end
	local ok, content = pcall(vim.json.encode, data)
	if not ok then
		-- 握り潰すと .state.json への永続化が黙ってスキップされ、
		-- 「設定したはずの内容が次回起動時に消えている」形で表面化する。
		-- すぐ下の atomic_write 失敗と同じく通知する。
		vim.notify(string.format("[gtodo-md] failed to encode %s: %s", path, tostring(content)), vim.log.levels.ERROR)
		return
	end
	-- config.lua がこのモジュールを require するため、io.lua はここで遅延requireする
	-- (io.lua は config.lua を require しており、トップレベルで書くと循環参照になる)。
	local io_mod = require("gtodo-md.io")
	local written, err = io_mod.atomic_write(path, content)
	if not written then
		vim.notify(string.format("[gtodo-md] failed to write %s: %s", path, err), vim.log.levels.ERROR)
		return
	end
	reported_broken[path] = nil
end

-- 読んで fn で書き換え、書き戻す。
--
-- 壊れたファイルは書き戻さない。以前は空として扱ってそのまま上書きしていたため、
-- 中身(CLI など他のツールが書いた知らないキーを含む)が消え、壊れていたことにも
-- 誰も気づけなかった。読む側は空として扱い続けるので、処理は止まらない
-- (日次ロールオーバーは記録できないが、同じセッションの中では1日1回に保たれる)。
local function update_state(fn)
	local data, broken = read_state()
	if broken then
		local path = get_state_path()
		if not reported_broken[path] then
			reported_broken[path] = true
			vim.notify(
				string.format(
					"[gtodo-md] %s is not a valid state file (%s); not overwriting it. Fix or remove the file.",
					path,
					broken
				),
				vim.log.levels.ERROR
			)
		end
		return
	end
	fn(data)
	write_state(data)
end

function M.read_last_opened()
	local state = read_state()
	return state.last_opened
end

function M.write_last_opened(date_str)
	update_state(function(state)
		state.last_opened = date_str
	end)
end

-- #94: 前回の setup() で使われていたセクション名(config.sections)を記憶する。
-- ユーザーがカスタム名を変更・削除した直後は、ファイル側の見出しがまだ
-- 前回の名前のままであることが多いため、config.section_aliases がこれも
-- 一時的にエイリアスとして受理することで、設定変更直後の保存がブロック
-- されず、次回保存時に新しい名前へ自動的に移行できるようにする
-- (全履歴ではなく直前の1世代分のみを覚える)。
function M.read_last_sections()
	local state = read_state()
	return state.last_sections
end

function M.write_last_sections(sections)
	update_state(function(state)
		state.last_sections = sections
	end)
end

function M.read_notify_state()
	local state = read_state()
	return state.last_notify_time or 0, state.last_notify_content or ""
end

function M.write_notify_state(time, content)
	update_state(function(state)
		state.last_notify_time = time
		state.last_notify_content = content
	end)
end

return M
