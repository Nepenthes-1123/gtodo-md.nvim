-- CLI/TUI と共有する設定ファイル (config.json・gtodo.json) の場所と読み取り。
--
-- 場所の規則と受理する値は CLI と同じでなければならない。食い違うと、2つのツールが
-- 別のディレクトリや別のセクション名で同じデータを読み書きする。ここのケースは
-- CLI 側のテスト (config.rs・settings.rs) と同じ入力を使っている。

local shared = require("gtodo-md.shared")

local SECTION_KEYS = { "TODAY", "NEXT", "WAITING", "SOMEDAY" }

local function env(vars)
	return function(name)
		return vars[name]
	end
end

describe("共有設定の場所", function()
	describe("絶対パスの判定", function()
		it("Unix では / で始まるパスだけを絶対パスとする", function()
			assert.is_true(shared._is_absolute("/a/b", false))
			assert.is_false(shared._is_absolute("a/b", false))
			assert.is_false(shared._is_absolute("", false))
			assert.is_false(shared._is_absolute("C:/a", false))
		end)

		it("Windows ではドライブ付きのパスと UNC パスを絶対パスとする", function()
			assert.is_true(shared._is_absolute("C:\\a", true))
			assert.is_true(shared._is_absolute("C:/a", true))
			assert.is_true(shared._is_absolute("\\\\server\\share", true))
			-- ドライブの無いパスは、カレントドライブによって場所が変わる。
			assert.is_false(shared._is_absolute("\\a", true))
			assert.is_false(shared._is_absolute("C:a", true))
			assert.is_false(shared._is_absolute("a\\b", true))
		end)
	end)

	describe("先頭の ~ の展開", function()
		local home = env({ HOME = "/home/me", USERPROFILE = "C:/Users/me" })

		it("~ と ~/ をホームディレクトリへ展開する", function()
			assert.are.equal("/home/me/todo", shared.expand_home("~/todo", home, false))
			assert.are.equal("/home/me", shared.expand_home("~", home, false))
		end)

		it("先頭以外の ~ と ~user は展開しない", function()
			assert.are.equal("/data/~/todo", shared.expand_home("/data/~/todo", home, false))
			assert.are.equal("~other/todo", shared.expand_home("~other/todo", home, false))
			assert.are.equal("relative/dir", shared.expand_home("relative/dir", home, false))
		end)

		it("Windows では USERPROFILE を使い、~\\ も展開する", function()
			assert.are.equal("C:/Users/me/todo", shared.expand_home("~/todo", home, true))
			assert.are.equal("C:/Users/me/todo", shared.expand_home("~\\todo", home, true))
		end)

		it("ホームディレクトリが分からなければ理由を返す", function()
			local dir, err = shared.expand_home("~/todo", env({}), false)
			assert.is_nil(dir)
			assert.is_truthy(err:find("home directory is unknown", 1, true))
		end)
	end)

	describe("config.json の場所", function()
		it("GTODO_CONFIG があればそのパスを明示的な指定として返す", function()
			local path, explicit =
				shared.config_path(env({ HOME = "/home/me", GTODO_CONFIG = "/etc/gtodo.json" }), false)
			assert.are.equal("/etc/gtodo.json", path)
			assert.is_true(explicit)
		end)

		it("Unix の既定は ~/.config/gtodo-md/config.json", function()
			local path, explicit = shared.config_path(env({ HOME = "/home/me" }), false)
			assert.are.equal("/home/me/.config/gtodo-md/config.json", path)
			assert.is_false(explicit)
		end)

		it("XDG_CONFIG_HOME があれば、どの OS でもそちらを使う", function()
			local vars = { HOME = "/home/me", USERPROFILE = "C:/Users/me", APPDATA = "C:/Roaming" }
			vars.XDG_CONFIG_HOME = "/xdg/config"
			assert.are.equal("/xdg/config/gtodo-md/config.json", (shared.config_path(env(vars), false)))
			vars.XDG_CONFIG_HOME = "D:/xdg"
			assert.are.equal("D:/xdg/gtodo-md/config.json", (shared.config_path(env(vars), true)))
		end)

		it("相対パスの XDG_CONFIG_HOME は無視する", function()
			local vars = { HOME = "/home/me", XDG_CONFIG_HOME = "relative/config" }
			assert.are.equal("/home/me/.config/gtodo-md/config.json", (shared.config_path(env(vars), false)))
		end)

		it("Windows の既定は %APPDATA%\\gtodo-md\\config.json", function()
			local vars = { USERPROFILE = "C:/Users/me", APPDATA = "C:/Users/me/AppData/Roaming" }
			assert.are.equal("C:/Users/me/AppData/Roaming/gtodo-md/config.json", (shared.config_path(env(vars), true)))
		end)

		it("Windows で APPDATA が無ければプロファイルのディレクトリから組み立てる", function()
			local vars = { USERPROFILE = "C:/Users/me" }
			assert.are.equal("C:/Users/me/AppData/Roaming/gtodo-md/config.json", (shared.config_path(env(vars), true)))
		end)

		it("ホームディレクトリが分からなければ場所を決めない", function()
			assert.is_nil((shared.config_path(env({}), false)))
		end)
	end)

	describe("既定の data_dir", function()
		it("Unix の既定は ~/.local/share/gtodo-md", function()
			assert.are.equal(
				"/home/me/.local/share/gtodo-md",
				shared.default_data_dir(env({ HOME = "/home/me" }), false)
			)
		end)

		it("XDG_DATA_HOME があれば、どの OS でもそちらを使う", function()
			local vars = { HOME = "/home/me", USERPROFILE = "C:/Users/me", LOCALAPPDATA = "C:/Local" }
			vars.XDG_DATA_HOME = "/xdg/data"
			assert.are.equal("/xdg/data/gtodo-md", shared.default_data_dir(env(vars), false))
			vars.XDG_DATA_HOME = "D:/xdg"
			assert.are.equal("D:/xdg/gtodo-md", shared.default_data_dir(env(vars), true))
		end)

		it("相対パスの XDG_DATA_HOME は無視する", function()
			local vars = { HOME = "/home/me", XDG_DATA_HOME = "relative/data" }
			assert.are.equal("/home/me/.local/share/gtodo-md", shared.default_data_dir(env(vars), false))
		end)

		it(
			"Windows の既定は %LOCALAPPDATA%\\gtodo-md、無ければプロファイルから組み立てる",
			function()
				local vars = { USERPROFILE = "C:/Users/me", LOCALAPPDATA = "C:/Users/me/AppData/Local" }
				assert.are.equal("C:/Users/me/AppData/Local/gtodo-md", shared.default_data_dir(env(vars), true))
				assert.are.equal(
					"C:/Users/me/AppData/Local/gtodo-md",
					shared.default_data_dir(env({ USERPROFILE = "C:/Users/me" }), true)
				)
			end
		)

		it("ホームディレクトリが分からなければ nil", function()
			assert.is_nil(shared.default_data_dir(env({}), false))
		end)
	end)

	describe("GTODO_DATA_DIR", function()
		it("未設定なら nil を返す", function()
			assert.is_nil((shared.env_data_dir(env({ HOME = "/home/me" }), false)))
		end)

		it("先頭の ~ を展開する", function()
			local vars = { HOME = "/home/me", GTODO_DATA_DIR = "~/env-todo" }
			assert.are.equal("/home/me/env-todo", (shared.env_data_dir(env(vars), false)))
		end)

		it("絶対パスはそのまま返す", function()
			local vars = { HOME = "/home/me", GTODO_DATA_DIR = "/from/env" }
			assert.are.equal("/from/env", (shared.env_data_dir(env(vars), false)))
		end)
	end)
end)

describe("共有設定の読み取り", function()
	local dir
	local home = env({ HOME = "/home/me" })

	before_each(function()
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
	end)

	after_each(function()
		vim.fn.delete(dir, "rf")
	end)

	-- 末尾に改行を足さずに書く(空のファイルを「空」として読ませるため)。
	local function write(name, content)
		local path = dir .. "/" .. name
		local f = assert(io.open(path, "wb"))
		f:write(content)
		f:close()
		return path
	end

	describe("config.json", function()
		it("既定の場所に無ければ、何も設定されていないものとして扱う", function()
			local result = shared.read_config(dir .. "/none.json", false, home, false)
			assert.is_nil(result.err)
			assert.is_nil(result.data_dir)
			assert.are.same({}, result.warnings)
		end)

		it("明示的に指定されたファイルが無ければエラーにする", function()
			local result = shared.read_config(dir .. "/none.json", true, home, false)
			assert.is_truthy(result.err:find("failed to read config file", 1, true))
			assert.is_nil(result.data_dir)
		end)

		it("data_dir を読む", function()
			local path = write("c.json", '{"data_dir":"/from/config"}')
			local result = shared.read_config(path, false, home, false)
			assert.is_nil(result.err)
			assert.are.equal("/from/config", result.data_dir)
		end)

		it("data_dir の先頭の ~ を展開する", function()
			local path = write("c.json", '{"data_dir":"~/todo"}')
			assert.are.equal("/home/me/todo", shared.read_config(path, false, home, false).data_dir)
		end)

		it("data_dir が無ければ、何も設定されていないものとして扱う", function()
			local result = shared.read_config(write("c.json", "{}"), false, home, false)
			assert.is_nil(result.err)
			assert.is_nil(result.data_dir)
		end)

		it("知らないキーは警告して無視する", function()
			local path = write("c.json", '{"data_dri":"/typo","data_dir":"/ok"}')
			local result = shared.read_config(path, false, home, false)
			assert.is_nil(result.err)
			assert.are.equal("/ok", result.data_dir)
			assert.are.equal(1, #result.warnings)
			assert.is_truthy(result.warnings[1]:find('"data_dri"', 1, true))
		end)

		it("読めない内容・型の違う値・相対パスはエラーにする", function()
			for _, content in ipairs({
				"",
				"{broken",
				"[]",
				'{"data_dir":1}',
				'{"data_dir":null}',
				'{"data_dir":""}',
				'{"data_dir":"relative/dir"}',
			}) do
				local result = shared.read_config(write("c.json", content), false, home, false)
				assert.is_truthy(
					result.err and result.err:find("invalid config file", 1, true),
					"エラーにならなかった: " .. vim.inspect(content) .. " -> " .. vim.inspect(result)
				)
				assert.is_nil(result.data_dir)
			end
		end)

		it("~ を展開できない data_dir はエラーにする", function()
			local path = write("c.json", '{"data_dir":"~/todo"}')
			local result = shared.read_config(path, false, env({}), false)
			assert.is_truthy(result.err:find("home directory is unknown", 1, true))
			assert.is_nil(result.data_dir)
		end)
	end)

	describe("gtodo.json", function()
		it("無ければ、何も設定されていないものとして扱う", function()
			local result = shared.read_settings(dir .. "/gtodo.json", SECTION_KEYS)
			assert.is_false(result.exists)
			assert.is_nil(result.err)
			assert.is_nil(result.sections)
			assert.is_nil(result.auto_move_inbox_to_today)
			assert.are.same({}, result.warnings)
		end)

		it("セクション名を小文字のキーで読み、setup() のキーで返す", function()
			local path = write("gtodo.json", '{"sections":{"today":"今日"},"auto_move_inbox_to_today":false}')
			local result = shared.read_settings(path, SECTION_KEYS)
			assert.is_true(result.exists)
			assert.is_nil(result.err)
			assert.are.same({ TODAY = "今日" }, result.sections)
			assert.is_false(result.auto_move_inbox_to_today)
			assert.are.same({}, result.warnings)
		end)

		-- "sections" があるかどうかで、書かれていないセクションの名前の決まり方が変わる
		-- (あればデフォルト名、無ければ setup() の名前)。空でも「ある」と区別できること。
		it("空の sections と、sections が無いことを区別する", function()
			local with = shared.read_settings(write("gtodo.json", '{"sections":{}}'), SECTION_KEYS)
			assert.are.same({}, with.sections)
			local without = shared.read_settings(write("gtodo.json", "{}"), SECTION_KEYS)
			assert.is_nil(without.sections)
			assert.is_nil(without.err)
		end)

		it("セクション名は書かれていたまま返す", function()
			local path = write("gtodo.json", '{"sections":{"today":"  今日  "}}')
			assert.are.equal("  今日  ", shared.read_settings(path, SECTION_KEYS).sections.TODAY)
		end)

		it("知らないキーと知らないセクションは警告して無視する", function()
			local path = write("gtodo.json", '{"future_option":1,"sections":{"tomorrow":"明日"}}')
			local result = shared.read_settings(path, SECTION_KEYS)
			assert.is_nil(result.err)
			assert.are.same({}, result.sections)
			assert.are.equal(2, #result.warnings)
			assert.is_truthy(result.warnings[1]:find('"future_option"', 1, true))
			assert.is_truthy(result.warnings[2]:find('"tomorrow"', 1, true))
		end)

		it("読めない内容・型の違う値はエラーにする", function()
			for _, content in ipairs({
				"",
				"{broken",
				"[]",
				'{"sections":[]}',
				'{"sections":{"today":1}}',
				'{"sections":{"today":null}}',
				'{"auto_move_inbox_to_today":"yes"}',
			}) do
				local result = shared.read_settings(write("gtodo.json", content), SECTION_KEYS)
				assert.is_truthy(
					result.err and result.err:find("is not a valid settings file", 1, true),
					"エラーにならなかった: " .. vim.inspect(content) .. " -> " .. vim.inspect(result)
				)
			end
		end)
	end)
end)
