-- setup() と、CLI/TUI と共有する設定ファイル (config.json・gtodo.json) の関係。
--
--   data_dir         setup() → GTODO_DATA_DIR → config.json → 既定
--   gtodo.json の項目  gtodo.json → setup() → 既定
--
-- data_dir は「どこを見るか」で、ツールごとに明示して変えてよい (CLI の --data-dir と同じ)。
-- gtodo.json は「そのディレクトリのデータの形」で、同じディレクトリを触るツールが別の値を
-- 使うと、互いが書くたびに見出しが書き換わり続ける。だから後者だけファイルを優先する。

local config = require("gtodo-md.config")

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR

local function capture_notifications(fn)
	local captured = {}
	local saved = vim.notify
	vim.notify = function(msg, level)
		table.insert(captured, { msg = tostring(msg), level = level })
	end
	local ok, err = pcall(fn)
	vim.notify = saved
	if not ok then
		error(err, 0)
	end
	return captured
end

local function has_notification(captured, level, ...)
	for _, n in ipairs(captured) do
		local matched = n.level == level
		for _, needle in ipairs({ ... }) do
			matched = matched and n.msg:find(needle, 1, true) ~= nil
		end
		if matched then
			return true
		end
	end
	return false
end

-- テストが書き換える環境変数。
local ENV_NAMES = { "GTODO_CONFIG", "GTODO_DATA_DIR", "XDG_CONFIG_HOME", "HOME" }

describe("共有設定と setup() の関係", function()
	local root
	local saved_env
	local saved_default_data_dir

	local function write(path, content)
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		local f = assert(io.open(path, "wb"))
		f:write(content)
		f:close()
		return path
	end

	-- config.json を作り、GTODO_CONFIG で指す。
	local function use_config(content)
		vim.env.GTODO_CONFIG = write(root .. "/config.json", content)
	end

	local function setup_and_capture(opts)
		return capture_notifications(function()
			config.setup(opts)
		end)
	end

	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		saved_env = {}
		for _, name in ipairs(ENV_NAMES) do
			saved_env[name] = vim.env[name]
		end
		-- 既定の data_dir は利用者の実データなので、テストの間は別の場所へ向ける。
		saved_default_data_dir = config.defaults.data_dir
		config.defaults.data_dir = root .. "/default"
		use_config("{}")
		vim.env.GTODO_DATA_DIR = nil
	end)

	after_each(function()
		-- 未設定だった変数は saved_env に入っていない。名前の一覧で回して未設定へ戻す。
		for _, name in ipairs(ENV_NAMES) do
			vim.env[name] = saved_env[name]
		end
		config.setup({ data_dir = root .. "/restore" }) -- 次のテストへ影響しないよう既定に戻す
		config.defaults.data_dir = saved_default_data_dir
		vim.fn.delete(root, "rf")
	end)

	describe("data_dir の決まり方", function()
		it("setup() の指定を最優先にする", function()
			vim.env.GTODO_DATA_DIR = root .. "/from-env"
			use_config(vim.json.encode({ data_dir = root .. "/from-config" }))

			setup_and_capture({ data_dir = root .. "/from-setup" })

			assert.are.equal(root .. "/from-setup", config.get("data_dir"))
			assert.are.equal("setup()", config.sources.data_dir)
		end)

		it("setup() に無ければ GTODO_DATA_DIR を使う", function()
			vim.env.GTODO_DATA_DIR = root .. "/from-env"
			use_config(vim.json.encode({ data_dir = root .. "/from-config" }))

			local captured = setup_and_capture({})

			assert.are.equal(root .. "/from-env", config.get("data_dir"))
			assert.are.equal("GTODO_DATA_DIR", config.sources.data_dir)
			assert.are.same({}, captured)
		end)

		it("どちらも無ければ config.json を使う", function()
			use_config(vim.json.encode({ data_dir = root .. "/from-config" }))

			local captured = setup_and_capture({})

			assert.are.equal(root .. "/from-config", config.get("data_dir"))
			assert.are.equal(vim.env.GTODO_CONFIG, config.sources.data_dir)
			assert.are.same({}, captured)
		end)

		it("何も無ければ既定の場所を使う", function()
			local captured = setup_and_capture({})

			assert.are.equal(root .. "/default", config.get("data_dir"))
			assert.are.equal("default", config.sources.data_dir)
			assert.are.same({}, captured)
		end)

		it("config.json の data_dir の ~ を展開する", function()
			vim.env.HOME = root .. "/home"
			use_config('{"data_dir":"~/todo"}')

			setup_and_capture({})

			assert.are.equal(root .. "/home/todo", config.get("data_dir"))
		end)

		it("決まった場所にデータディレクトリを作る", function()
			use_config(vim.json.encode({ data_dir = root .. "/from-config" }))

			setup_and_capture({})

			assert.are.equal(1, vim.fn.isdirectory(root .. "/from-config/projects"))
			assert.are.equal(0, vim.fn.isdirectory(root .. "/default"))
		end)

		-- GTODO_DATA_DIR があるとき CLI は config.json を読まない。こちらだけ読んで
		-- エラーを出すと、CLI では問題にならない設定で起動のたびに通知が出る。
		it("GTODO_DATA_DIR があれば config.json は読まない", function()
			vim.env.GTODO_DATA_DIR = root .. "/from-env"
			use_config("{broken")

			local captured = setup_and_capture({})

			assert.are.equal(root .. "/from-env", config.get("data_dir"))
			assert.are.same({}, captured)
		end)

		it("既定の場所に config.json が無くても通知しない", function()
			vim.env.GTODO_CONFIG = nil
			vim.env.XDG_CONFIG_HOME = root .. "/xdg"

			local captured = setup_and_capture({})

			assert.are.equal(root .. "/default", config.get("data_dir"))
			assert.are.same({}, captured)
		end)
	end)

	describe("data_dir の食い違い", function()
		it("setup() の指定が config.json と違えば警告する", function()
			use_config(vim.json.encode({ data_dir = root .. "/from-config" }))

			local captured = setup_and_capture({ data_dir = root .. "/from-setup" })

			assert.are.equal(root .. "/from-setup", config.get("data_dir"))
			assert.is_true(
				has_notification(captured, WARN, root .. "/from-setup", root .. "/from-config", vim.env.GTODO_CONFIG),
				"どの場所とどの場所が食い違っているかが通知から読み取れない: "
					.. vim.inspect(captured)
			)
		end)

		it("setup() の指定が GTODO_DATA_DIR と違えば警告する", function()
			vim.env.GTODO_DATA_DIR = root .. "/from-env"

			local captured = setup_and_capture({ data_dir = root .. "/from-setup" })

			assert.is_true(has_notification(captured, WARN, root .. "/from-env", "GTODO_DATA_DIR"))
		end)

		it("同じ場所を指していれば、書き方が違っても警告しない", function()
			use_config(vim.json.encode({ data_dir = root .. "/data/" }))
			vim.fn.mkdir(root .. "/sub", "p")

			local captured = setup_and_capture({ data_dir = root .. "/sub/../data" })

			assert.are.same({}, captured)
		end)

		it("共有設定が data_dir を決めていなければ警告しない", function()
			local captured = setup_and_capture({ data_dir = root .. "/from-setup" })

			assert.are.same({}, captured)
		end)
	end)

	describe("使えない config.json", function()
		it("エラーを通知し、無いものとして既定の場所を使う", function()
			use_config('{"data_dir":"relative/dir"}')

			local captured = setup_and_capture({})

			assert.are.equal(root .. "/default", config.get("data_dir"))
			assert.is_true(has_notification(captured, ERROR, "invalid config file", vim.env.GTODO_CONFIG))
		end)

		-- CLI はこのファイルで止まる。setup() の指定で動けていても、直すべきことは伝える。
		it("setup() が data_dir を指定していてもエラーを通知する", function()
			use_config("{broken")

			local captured = setup_and_capture({ data_dir = root .. "/from-setup" })

			assert.are.equal(root .. "/from-setup", config.get("data_dir"))
			assert.is_true(has_notification(captured, ERROR, "invalid config file"))
		end)

		it("GTODO_CONFIG が指すファイルが無ければエラーを通知する", function()
			vim.env.GTODO_CONFIG = root .. "/none.json"

			local captured = setup_and_capture({})

			assert.are.equal(root .. "/default", config.get("data_dir"))
			assert.is_true(has_notification(captured, ERROR, "failed to read config file"))
		end)

		it("知らないキーは警告するだけで、data_dir は使う", function()
			use_config(vim.json.encode({ data_dri = "/typo", data_dir = root .. "/from-config" }))

			local captured = setup_and_capture({})

			assert.are.equal(root .. "/from-config", config.get("data_dir"))
			assert.is_true(has_notification(captured, WARN, '"data_dri"'))
			assert.is_false(has_notification(captured, ERROR))
		end)
	end)

	describe("gtodo.json", function()
		local data_dir
		local settings_path

		local function use_settings(content)
			write(settings_path, content)
		end

		before_each(function()
			data_dir = root .. "/data"
			settings_path = data_dir .. "/gtodo.json"
		end)

		it("無ければ setup() の値をそのまま使い、通知しない", function()
			local captured = setup_and_capture({
				data_dir = data_dir,
				sections = { TODAY = "今日" },
				auto_move_inbox_to_today = false,
			})

			assert.are.equal("今日", config.sections.TODAY)
			assert.is_false(config.get("auto_move_inbox_to_today"))
			assert.are.equal("setup()", config.sources.sections)
			assert.are.same({}, captured)
		end)

		it(
			"data_dir を config.json が決めたときも、そのディレクトリの gtodo.json を読む",
			function()
				use_config(vim.json.encode({ data_dir = data_dir }))
				use_settings('{"sections":{"today":"今日"}}')

				setup_and_capture({})

				assert.are.equal("今日", config.sections.TODAY)
			end
		)

		describe("セクション名", function()
			it("gtodo.json の名前を使う", function()
				use_settings('{"sections":{"today":"今日","next":"次"}}')

				local captured = setup_and_capture({ data_dir = data_dir })

				assert.are.same(
					{ TODAY = "今日", NEXT = "次", WAITING = "Waiting", SOMEDAY = "Someday" },
					config.sections
				)
				assert.are.equal(settings_path, config.sources.sections)
				assert.are.same({}, captured)
			end)

			it("前後の空白を落として使う", function()
				use_settings('{"sections":{"today":"  今日  "}}')

				setup_and_capture({ data_dir = data_dir })

				assert.are.equal("今日", config.sections.TODAY)
			end)

			-- CLI は sections があれば 4 つともそこから決め、書かれていないものはデフォルト名にする。
			-- 書かれていないキーだけ setup() の名前を使うと、そのセクションの見出しを
			-- CLI はデフォルト名で、こちらは setup() の名前で書き、書くたびに入れ替わる。
			it(
				"sections があれば、書かれていないセクションは setup() ではなくデフォルト名にする",
				function()
					use_settings('{"sections":{"today":"今日"}}')

					local captured = setup_and_capture({ data_dir = data_dir, sections = { NEXT = "次" } })

					assert.are.equal("今日", config.sections.TODAY)
					assert.are.equal("Next", config.sections.NEXT)
					assert.is_true(
						has_notification(captured, WARN, "NEXT", settings_path),
						"使われなかった setup() の名前が通知から読み取れない: "
							.. vim.inspect(captured)
					)
				end
			)

			it("setup() の名前が gtodo.json と違えば警告し、gtodo.json を使う", function()
				use_settings('{"sections":{"today":"今日","next":"次"}}')

				local captured =
					setup_and_capture({ data_dir = data_dir, sections = { TODAY = "きょう", NEXT = "つぎ" } })

				assert.are.equal("今日", config.sections.TODAY)
				assert.are.equal("次", config.sections.NEXT)
				assert.is_true(has_notification(captured, WARN, "NEXT, TODAY", settings_path))
			end)

			it("setup() の名前が gtodo.json と同じなら警告しない", function()
				use_settings('{"sections":{"today":"今日"}}')

				local captured = setup_and_capture({ data_dir = data_dir, sections = { TODAY = " 今日 " } })

				assert.are.same({}, captured)
			end)

			-- setup() の名前は使わないので、その誤りを直させても結果は変わらない。
			it("使わない setup() の名前の誤りは通知しない", function()
				use_settings('{"sections":{"today":"今日"}}')

				local captured = setup_and_capture({ data_dir = data_dir, sections = { TODAY = "今日", NEXT = "" } })

				assert.is_false(has_notification(captured, ERROR))
			end)

			it("sections が無い gtodo.json では setup() の名前を使う", function()
				use_settings('{"auto_move_inbox_to_today":true}')

				local captured = setup_and_capture({ data_dir = data_dir, sections = { TODAY = "今日" } })

				assert.are.equal("今日", config.sections.TODAY)
				assert.are.equal("setup()", config.sources.sections)
				assert.are.same({}, captured)
			end)

			it("gtodo.json の名前を前回の名前として記憶する", function()
				use_settings('{"sections":{"today":"今日"}}')

				setup_and_capture({ data_dir = data_dir, sections = { TODAY = "きょう" } })

				assert.are.equal("今日", require("gtodo-md.state").read_last_sections().TODAY)
			end)

			it("既存ファイルのデフォルト名の見出しを gtodo.json の名前として読む", function()
				use_settings('{"sections":{"today":"今日"}}')
				setup_and_capture({ data_dir = data_dir })

				local data = require("gtodo-md.io").parse_markdown({ "# Todo", "", "## Today", "", "- [ ] タスク" })

				assert.are.equal("タスク", data.sections["今日"][1].task.content)
			end)
		end)

		describe("auto_move_inbox_to_today", function()
			it("gtodo.json の値を使う", function()
				use_settings('{"auto_move_inbox_to_today":false}')

				local captured = setup_and_capture({ data_dir = data_dir })

				assert.is_false(config.get("auto_move_inbox_to_today"))
				assert.are.same({}, captured)
			end)

			it("setup() の値が gtodo.json と違えば警告し、gtodo.json を使う", function()
				use_settings('{"auto_move_inbox_to_today":true}')

				local captured = setup_and_capture({ data_dir = data_dir, auto_move_inbox_to_today = false })

				assert.is_true(config.get("auto_move_inbox_to_today"))
				assert.is_true(has_notification(captured, WARN, "auto_move_inbox_to_today", settings_path))
			end)

			it("setup() の値が gtodo.json と同じなら警告しない", function()
				use_settings('{"auto_move_inbox_to_today":false}')

				local captured = setup_and_capture({ data_dir = data_dir, auto_move_inbox_to_today = false })

				assert.are.same({}, captured)
			end)

			it("gtodo.json に無ければ setup() の値を使う", function()
				use_settings('{"sections":{"today":"今日"}}')

				local captured = setup_and_capture({ data_dir = data_dir, auto_move_inbox_to_today = false })

				assert.is_false(config.get("auto_move_inbox_to_today"))
				assert.are.same({}, captured)
			end)
		end)

		describe("使えない gtodo.json", function()
			-- CLI はこのファイルで止まる。こちらは止まれないので、ファイル全体を無いものとして
			-- 扱う。読めた項目だけ使うと、CLI が一度も使っていない値で動くことになる。
			it("エラーを通知し、ファイル全体を無いものとして setup() の値を使う", function()
				for _, content in ipairs({
					"",
					"{broken",
					"[]",
					'{"sections":[],"auto_move_inbox_to_today":false}',
					'{"sections":{"today":1},"auto_move_inbox_to_today":false}',
					'{"sections":{"today":"  "},"auto_move_inbox_to_today":false}',
					'{"sections":{"today":"Next"},"auto_move_inbox_to_today":false}',
					'{"sections":{"today":"同じ","next":"同じ"},"auto_move_inbox_to_today":false}',
					'{"sections":{"today":"今日"},"auto_move_inbox_to_today":"yes"}',
				}) do
					use_settings(content)

					local captured = setup_and_capture({ data_dir = data_dir, sections = { SOMEDAY = "いつか" } })

					local label = vim.inspect(content) .. " -> " .. vim.inspect(captured)
					assert.is_true(
						has_notification(captured, ERROR, settings_path),
						"エラーが通知されない: " .. label
					)
					assert.are.same(
						{ TODAY = "Today", NEXT = "Next", WAITING = "Waiting", SOMEDAY = "いつか" },
						config.sections,
						label
					)
					assert.is_true(config.get("auto_move_inbox_to_today"), label)
				end
			end)

			it("知らないキーは警告するだけで、他の項目は使う", function()
				use_settings('{"future_option":1,"sections":{"today":"今日","tomorrow":"明日"}}')

				local captured = setup_and_capture({ data_dir = data_dir })

				assert.are.equal("今日", config.sections.TODAY)
				assert.is_true(has_notification(captured, WARN, '"future_option"'))
				assert.is_true(has_notification(captured, WARN, '"tomorrow"'))
				assert.is_false(has_notification(captured, ERROR))
			end)
		end)
	end)

	-- 作ると、その時点の値が共有ファイルに固定される。以後は setup() を変えても
	-- gtodo.json が優先されるため、CLI を使わない利用者の設定変更まで効かなくなる。
	it("setup() は共有設定のファイルを作らない", function()
		vim.env.GTODO_CONFIG = nil
		vim.env.XDG_CONFIG_HOME = root .. "/xdg"

		setup_and_capture({ sections = { TODAY = "今日" }, auto_move_inbox_to_today = false })

		assert.are.equal(0, vim.fn.filereadable(root .. "/xdg/gtodo-md/config.json"))
		assert.are.equal(0, vim.fn.filereadable(config.get("data_dir") .. "/gtodo.json"))
	end)
end)
