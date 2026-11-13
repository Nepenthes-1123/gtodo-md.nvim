-- gtodo の CLI/TUI と共有する設定ファイルの場所と読み取り。
--
-- 設定は2つのファイルに分かれる(どちらも利用者が手で作る。このプラグインは作らない)。
--   config.json            data_dir の場所だけ
--   <data_dir>/gtodo.json  セクション名など、データの形と自動処理に関わる設定
--
-- ここが受け持つのは「どこにあるか」と「何が書いてあるか」まで。setup() の値との
-- 優先順位・セクション名の妥当性・利用者への通知は config.lua が決める。
--
-- 場所の規則と受理する値は CLI と揃えること。食い違うと、2つのツールが別の
-- ディレクトリや別のセクション名で同じデータを読み書きする。
-- 環境変数と OS の種別を引数で受け取るのは、どの OS の規則もテストできるようにするため。
local M = {}

local uv = vim.uv

local APP_DIR = "gtodo-md"

-- 環境変数を読む。値が空の変数は未設定として扱う。
function M.process_env(name)
	local value = vim.env[name]
	if value == nil or value == "" then
		return nil
	end
	return value
end

function M.is_windows()
	return vim.fn.has("win32") == 1
end

function M._is_absolute(path, windows)
	if windows then
		return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
	end
	return path:sub(1, 1) == "/"
end

local function home_dir(env, windows)
	return env(windows and "USERPROFILE" or "HOME")
end

-- 相対パスの値は無効として扱う(XDG の仕様どおり)。
-- カレントディレクトリによって場所が変わる設定は、意図したものと考えにくい。
local function absolute_var(env, name, windows)
	local value = env(name)
	if value and M._is_absolute(value, windows) then
		return value
	end
	return nil
end

-- 先頭の `~` をホームディレクトリへ展開する(設定ファイルや環境変数の値はシェルが展開しないため)。
-- 展開できなければ nil と理由を返す。
function M.expand_home(path, env, windows)
	local rest
	if path == "~" then
		rest = ""
	elseif path:sub(1, 2) == "~/" or (windows and path:sub(1, 2) == "~\\") then
		rest = path:sub(3)
	else
		return path
	end
	local home = home_dir(env, windows)
	if not home then
		return nil, string.format("cannot expand '~' in %s: home directory is unknown", path)
	end
	if rest == "" then
		return home
	end
	return vim.fs.joinpath(home, rest)
end

-- config.json のパスと、GTODO_CONFIG で明示的に指定されたものかを返す。
-- 既定の場所を決められなければ nil。
function M.config_path(env, windows)
	local explicit = env("GTODO_CONFIG")
	if explicit then
		return explicit, true
	end
	local base = absolute_var(env, "XDG_CONFIG_HOME", windows)
	if not base then
		local home = home_dir(env, windows)
		if windows then
			base = env("APPDATA") or (home and vim.fs.joinpath(home, "AppData", "Roaming"))
		else
			base = home and vim.fs.joinpath(home, ".config")
		end
	end
	if not base then
		return nil, false
	end
	return vim.fs.joinpath(base, APP_DIR, "config.json"), false
end

-- 既定の data_dir (新しい既定)。CLI と同じ規則で決める。ホームディレクトリが分からなければ nil。
-- `$XDG_DATA_HOME/gtodo-md`。XDG_DATA_HOME が無ければ Unix (macOS を含む) は
-- `~/.local/share/gtodo-md`、Windows は `%LOCALAPPDATA%\gtodo-md`。
-- 旧い既定 (stdpath("data") .. "/gtodo-md") へ戻るかどうかは呼び出し元が決める。
function M.default_data_dir(env, windows)
	local base = absolute_var(env, "XDG_DATA_HOME", windows)
	if not base then
		local home = home_dir(env, windows)
		if windows then
			base = env("LOCALAPPDATA") or (home and vim.fs.joinpath(home, "AppData", "Local"))
		else
			base = home and vim.fs.joinpath(home, ".local", "share")
		end
	end
	if not base then
		return nil
	end
	return vim.fs.joinpath(base, APP_DIR)
end

-- 既定の名前 (NVIM_APPNAME 無し) で起動した Neovim の stdpath("data") .. "/gtodo-md" を、CLI と
-- 同じ規則で組み立てる。ホームディレクトリが分からなければ nil。
-- 別の名前で起動した Neovim が、このディレクトリのデータを見落として新しい既定を作らないために使う。
function M.default_neovim_data_dir(env, windows)
	local base = absolute_var(env, "XDG_DATA_HOME", windows)
	if not base then
		local home = home_dir(env, windows)
		if windows then
			base = env("LOCALAPPDATA") or (home and vim.fs.joinpath(home, "AppData", "Local"))
		else
			base = home and vim.fs.joinpath(home, ".local", "share")
		end
	end
	if not base then
		return nil
	end
	return vim.fs.joinpath(base, windows and "nvim-data" or "nvim", APP_DIR)
end

-- GTODO_DATA_DIR の値(先頭の `~` は展開する)。未設定なら nil。
-- 展開できなければ nil と理由を返す。
function M.env_data_dir(env, windows)
	local dir = env("GTODO_DATA_DIR")
	if not dir then
		return nil
	end
	return M.expand_home(dir, env, windows)
end

-- ファイル全体を読む。読めなければ nil・「ファイルが無い」かどうか・理由を返す。
local function read_file(path)
	local fd, open_err, err_name = uv.fs_open(path, "r", 438)
	if not fd then
		return nil, err_name == "ENOENT", open_err
	end
	local stat, stat_err = uv.fs_fstat(fd)
	if not stat then
		uv.fs_close(fd)
		return nil, false, stat_err
	end
	local text, read_err = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	if not text then
		return nil, false, read_err
	end
	return text, false, nil
end

local function is_object(value)
	return type(value) == "table" and not vim.islist(value)
end

local function decode_object(text)
	local ok, value = pcall(vim.json.decode, text)
	if not ok then
		return nil, tostring(value)
	end
	if not is_object(value) then
		return nil, "top level is not an object"
	end
	return value
end

-- 警告の順序を実行のたびに変えないため、キーは並べてから見る。
local function sorted_keys(object)
	local keys = vim.tbl_keys(object)
	table.sort(keys)
	return keys
end

-- config.json を読む。
--
-- 戻り値は { data_dir = 絶対パス | nil, warnings = {...}, err = 理由 | nil }。
-- err があるとき、このファイルは使えない。warnings は処理を続けられる問題。
--
-- 知らないキーでは止めない。バージョンの違うツール同士で同じファイルを読むため。
function M.read_config(path, explicit, env, windows)
	local result = { warnings = {} }
	local text, missing, io_err = read_file(path)
	if not text then
		-- 既定の場所に無いのは普通のこと。明示的に指定されたファイルが無いのは指定の誤り。
		if not (missing and not explicit) then
			result.err = string.format("failed to read config file %s: %s", path, io_err)
		end
		return result
	end

	local function invalid(reason)
		result.err = string.format("invalid config file %s: %s", path, reason)
		return result
	end

	local top, reason = decode_object(text)
	if not top then
		return invalid(reason)
	end
	local data_dir
	for _, key in ipairs(sorted_keys(top)) do
		if key == "data_dir" then
			if type(top[key]) ~= "string" then
				return invalid('"data_dir" is not a string')
			end
			data_dir = top[key]
		else
			table.insert(result.warnings, string.format('%s: unknown key "%s" is ignored', path, key))
		end
	end
	if data_dir == nil then
		return result
	end

	local expanded, home_err = M.expand_home(data_dir, env, windows)
	if not expanded then
		result.err = home_err
		return result
	end
	-- 相対パスの XDG_* を無視するのと同じく、実行したディレクトリで場所が変わる設定は受け付けない。
	if not M._is_absolute(expanded, windows) then
		return invalid(string.format('"data_dir" must be an absolute path or start with \'~\', got "%s"', data_dir))
	end
	result.data_dir = expanded
	return result
end

-- <data_dir>/gtodo.json を読む。
--
-- section_keys は setup() で使うセクションのキー(TODAY など)。ファイルでは小文字で書く。
--
-- 戻り値は {
--   exists = ファイルがあるか,
--   sections = { [キー] = 書かれていた名前 } | nil,  -- "sections" が無ければ nil
--   auto_move_inbox_to_today = boolean | nil,         -- 書かれていなければ nil
--   warnings = {...},
--   err = 理由 | nil,
-- }。err があるとき、このファイルは使えない。
--
-- セクション名は書かれていたまま返す。空の名前や重複の判定は、setup() の値に対する
-- 判定と同じ規則を使う config.lua が行う。
function M.read_settings(path, section_keys)
	local result = { exists = false, warnings = {} }
	local text, missing, io_err = read_file(path)
	if not text then
		if not missing then
			result.exists = true
			result.err = string.format("failed to read %s: %s", path, io_err)
		end
		return result
	end
	result.exists = true

	local function invalid(reason)
		result.err = string.format("%s is not a valid settings file: %s", path, reason)
		return result
	end

	local top, reason = decode_object(text)
	if not top then
		return invalid(reason)
	end

	local sections, auto_move
	for _, key in ipairs(sorted_keys(top)) do
		local value = top[key]
		if key == "sections" then
			if not is_object(value) then
				return invalid('"sections" is not an object')
			end
			local known = {}
			sections = {}
			for _, section_key in ipairs(section_keys) do
				local file_key = section_key:lower()
				known[file_key] = true
				local name = value[file_key]
				if name ~= nil then
					if type(name) ~= "string" then
						return invalid(string.format('section name for "%s" is not a string', file_key))
					end
					sections[section_key] = name
				end
			end
			for _, file_key in ipairs(sorted_keys(value)) do
				if not known[file_key] then
					table.insert(result.warnings, string.format('%s: unknown section "%s" is ignored', path, file_key))
				end
			end
		elseif key == "auto_move_inbox_to_today" then
			if type(value) ~= "boolean" then
				return invalid('"auto_move_inbox_to_today" is not a boolean')
			end
			auto_move = value
		else
			table.insert(result.warnings, string.format('%s: unknown key "%s" is ignored', path, key))
		end
	end

	result.sections = sections
	result.auto_move_inbox_to_today = auto_move
	return result
end

return M
