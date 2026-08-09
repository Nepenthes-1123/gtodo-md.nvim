-- data_dir/.state.json の読み書き。日次ロールオーバーのゲート(last_opened)、
-- セクション名カスタマイズの前回名記憶(last_sections)、due通知のクールダウン
-- 状態(last_notify_*)といった、アプリケーション状態の永続化を一手に引き受ける。
local M = {}

local function get_state_path()
	local config = require("gtodo-md.config")
	local data_dir = config.get("data_dir")
	return data_dir .. "/.state.json"
end

local function read_state()
	local path = get_state_path()
	local f = io.open(path, "r")
	if not f then
		return {}
	end
	local content = f:read("*all")
	f:close()
	if not content or content == "" then
		return {}
	end
	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function write_state(data)
	local path = get_state_path()
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		-- mkdir() は失敗時に 0 を返すほか、パス上に同名のファイルがある等では
		-- E739 を投げる。素通しにすると `setup()` の途中で例外が飛び、プラグイン全体の
		-- 初期化がそこで止まる(しかもユーザーには原因が読み取れない)。
		local ok, created = pcall(vim.fn.mkdir, dir, "p")
		if not ok or created == 0 then
			vim.notify(string.format("[gtodo-md] failed to create data directory: %s", dir), vim.log.levels.ERROR)
			return
		end
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
	end
end

function M.read_last_opened()
	local state = read_state()
	return state.last_opened
end

function M.write_last_opened(date_str)
	local state = read_state()
	state.last_opened = date_str
	write_state(state)
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
	local state = read_state()
	state.last_sections = sections
	write_state(state)
end

function M.read_notify_state()
	local state = read_state()
	return state.last_notify_time or 0, state.last_notify_content or ""
end

function M.write_notify_state(time, content)
	local state = read_state()
	state.last_notify_time = time
	state.last_notify_content = content
	write_state(state)
end

return M
