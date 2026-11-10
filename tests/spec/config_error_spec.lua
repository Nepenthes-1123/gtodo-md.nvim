-- 設定・環境まわりのエラーが無通知で握り潰されると、症状だけが残って原因に
-- 辿り着けない。データ消失は伴わないが、「保存が効かない」「設定が保存されない」
-- という形で表面化し、ユーザーが自力で診断できない。

local config = require("gtodo-md.config")

-- vim.notify を差し替えて記録する。level は最も重いものを見たいので全件保持する。
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

local function has_error_matching(captured, needle)
	for _, n in ipairs(captured) do
		if n.level == vim.log.levels.ERROR and n.msg:find(needle, 1, true) then
			return true
		end
	end
	return false
end

describe("設定・環境エラーの通知", function()
	local saved_data_dir
	local saved_sections

	before_each(function()
		saved_data_dir = config.options.data_dir
		saved_sections = vim.tbl_extend("force", {}, config.sections)
	end)

	after_each(function()
		config.options.data_dir = saved_data_dir
		config.sections = saved_sections
	end)

	describe("data_dir の作成失敗", function()
		it("ディレクトリを作れない場合は通知する", function()
			-- 既存の**ファイル**を data_dir に指定すると、その配下は作成できない
			local blocker = vim.fn.tempname()
			vim.fn.writefile({ "" }, blocker)

			local captured = capture_notifications(function()
				config.setup({ data_dir = blocker })
			end)

			assert.is_true(
				has_error_matching(captured, "failed to create data directory"),
				"ディレクトリ作成の失敗が無通知で握り潰されている"
			)

			vim.fn.delete(blocker)
		end)

		it("正常に作成できる場合は通知しない", function()
			local dir = vim.fn.tempname()

			local captured = capture_notifications(function()
				config.setup({ data_dir = dir })
			end)

			assert.is_false(has_error_matching(captured, "failed to create data directory"))
			assert.are.equal(1, vim.fn.isdirectory(dir .. "/projects"))

			vim.fn.delete(dir, "rf")
		end)
	end)

	describe("セクション名の検証", function()
		local data_dir

		before_each(function()
			data_dir = vim.fn.tempname()
		end)

		after_each(function()
			vim.fn.delete(data_dir, "rf")
		end)

		-- 空文字を通すと ensure_files が `## ` という見出しの無い todo.md を作る一方、
		-- section_aliases はデフォルト名しか候補に返さないため必須セクションが永遠に
		-- 見つからず、保存が恒久的にブロックされる。
		it("空文字のセクション名はデフォルトへ差し戻し、通知する", function()
			local captured = capture_notifications(function()
				config.setup({ data_dir = data_dir, sections = { TODAY = "" } })
			end)

			assert.are.equal(config.default_sections.TODAY, config.sections.TODAY)
			assert.is_true(has_error_matching(captured, "section names must be non-empty"))
		end)

		it("空白のみのセクション名も差し戻す", function()
			capture_notifications(function()
				config.setup({ data_dir = data_dir, sections = { NEXT = "   " } })
			end)

			assert.are.equal(config.default_sections.NEXT, config.sections.NEXT)
		end)

		it("文字列でない値も差し戻す", function()
			capture_notifications(function()
				config.setup({ data_dir = data_dir, sections = { WAITING = 42 } })
			end)

			assert.are.equal(config.default_sections.WAITING, config.sections.WAITING)
		end)

		it("差し戻したキーだけが影響を受け、他のカスタム名は保たれる", function()
			capture_notifications(function()
				config.setup({ data_dir = data_dir, sections = { TODAY = "", SOMEDAY = "いつか" } })
			end)

			assert.are.equal(config.default_sections.TODAY, config.sections.TODAY)
			assert.are.equal("いつか", config.sections.SOMEDAY)
		end)

		it("正当なカスタム名は前後の空白を落として受理する", function()
			local captured = capture_notifications(function()
				config.setup({ data_dir = data_dir, sections = { TODAY = "  今日  " } })
			end)

			assert.are.equal("今日", config.sections.TODAY)
			assert.is_false(has_error_matching(captured, "section names must be non-empty"))
		end)

		-- 差し戻した結果、必須セクションの検証が通ること(＝保存がブロックされないこと)
		it("差し戻し後は必須セクションの検証を通過する", function()
			capture_notifications(function()
				config.setup({ data_dir = data_dir, sections = { TODAY = "" } })
			end)

			local lines = {
				"# Todo",
				"",
				"## " .. config.sections.TODAY,
				"## " .. config.sections.NEXT,
				"## " .. config.sections.WAITING,
				"## " .. config.sections.SOMEDAY,
			}

			assert.are.same({}, require("gtodo-md.validate").missing_todo_sections(lines))
		end)

		-- 2つのキーが同じ見出しを指すと、parse_markdown が両方の見出しを同じ名前へ
		-- 正規化して1つのセクションとして読み、write_todo_file がそのまま1つの見出しで
		-- 書き戻す。セクションの区別がディスクから無通知で失われる。
		describe("重複の検証", function()
			local function setup_and_capture(sections)
				return capture_notifications(function()
					config.setup({ data_dir = data_dir, sections = sections })
				end)
			end

			it(
				"2つのキーに同じ名前を付けたら両方をデフォルトへ差し戻し、通知する",
				function()
					local captured = setup_and_capture({ TODAY = "やること", NEXT = "やること" })

					assert.are.equal(config.default_sections.TODAY, config.sections.TODAY)
					assert.are.equal(config.default_sections.NEXT, config.sections.NEXT)
					assert.is_true(has_error_matching(captured, "section names must be unique"))
					assert.is_true(
						has_error_matching(captured, "NEXT, TODAY"),
						"どのキーを差し戻したかが通知から読み取れない: " .. vim.inspect(captured)
					)
				end
			)

			it("前後の空白を落とした結果が重なる場合も差し戻す", function()
				setup_and_capture({ TODAY = "  やること  ", NEXT = "やること" })

				assert.are.equal(config.default_sections.TODAY, config.sections.TODAY)
				assert.are.equal(config.default_sections.NEXT, config.sections.NEXT)
			end)

			it("他のキーが使っているデフォルト名を付けたら差し戻す", function()
				local captured = setup_and_capture({ TODAY = "Next" })

				assert.are.equal(config.default_sections.TODAY, config.sections.TODAY)
				assert.are.equal(config.default_sections.NEXT, config.sections.NEXT)
				-- NEXT は元からデフォルト名で、利用者が設定したものではない。
				-- 差し戻したキーとして挙げると、設定していない項目を直せと言うことになる。
				assert.is_true(has_error_matching(captured, "defaults for: TODAY"))
				assert.is_false(has_error_matching(captured, "NEXT"))
			end)

			-- デフォルト名は別名として受理され続けるため、相手が名前を変えていても
			-- 既存ファイルの `## Next` がどちらのセクションか決まらなくなる。
			it(
				"他のキーのデフォルト名は、そのキーが別の名前へ変えていても使えない",
				function()
					local captured = setup_and_capture({ TODAY = "Next", NEXT = "あとで" })

					assert.are.equal(config.default_sections.TODAY, config.sections.TODAY)
					assert.are.equal("あとで", config.sections.NEXT)
					assert.is_true(has_error_matching(captured, "defaults for: TODAY"))
				end
			)

			it("重なっていないキーのカスタム名は保たれる", function()
				setup_and_capture({ TODAY = "やること", NEXT = "やること", SOMEDAY = "いつか" })

				assert.are.equal("いつか", config.sections.SOMEDAY)
				assert.are.equal(config.default_sections.WAITING, config.sections.WAITING)
			end)

			-- 差し戻した先のデフォルト名を別のキーが使っていると、差し戻しが新しい重複を作る。
			it("差し戻した結果どうしも重ならない", function()
				setup_and_capture({ TODAY = "やること", NEXT = "やること", WAITING = "Today" })

				local seen = {}
				for key, name in pairs(config.sections) do
					assert.is_nil(seen[name], key .. " と " .. tostring(seen[name]) .. " が同じ名前: " .. name)
					seen[name] = key
				end
				assert.are.same(config.default_sections, config.sections)
			end)

			it("空の名前の差し戻し先を別のキーが使っている場合も差し戻す", function()
				local captured = setup_and_capture({ TODAY = "", NEXT = "Today" })

				assert.are.same(config.default_sections, config.sections)
				assert.is_true(has_error_matching(captured, "section names must be non-empty"))
				assert.is_true(has_error_matching(captured, "section names must be unique"))
			end)

			it("自分のデフォルト名を明示しても重複として扱わない", function()
				local captured = setup_and_capture({ TODAY = "Today", NEXT = "次" })

				assert.are.equal("Today", config.sections.TODAY)
				assert.are.equal("次", config.sections.NEXT)
				assert.is_false(has_error_matching(captured, "section names must be unique"))
			end)

			it("重なりの無いカスタム名では通知しない", function()
				local captured =
					setup_and_capture({ TODAY = "今日", NEXT = "次", WAITING = "待ち", SOMEDAY = "いつか" })

				assert.are.same(
					{ TODAY = "今日", NEXT = "次", WAITING = "待ち", SOMEDAY = "いつか" },
					config.sections
				)
				assert.are.same({}, captured)
			end)

			it(
				"重複した設定でも、Today と Next の見出しは別のセクションとして読み書きされる",
				function()
					setup_and_capture({ TODAY = "やること", NEXT = "やること" })
					local io_mod = require("gtodo-md.io")

					local data = io_mod.parse_markdown({
						"# Todo",
						"",
						"## Today",
						"",
						"- [ ] 今日のタスク",
						"",
						"## Next",
						"",
						"- [ ] 次のタスク",
						"",
						"## Waiting",
						"",
						"## Someday",
					})

					assert.are.equal(1, #data.sections[config.sections.TODAY])
					assert.are.equal(1, #data.sections[config.sections.NEXT])
					assert.are.equal("今日のタスク", data.sections[config.sections.TODAY][1].task.content)
					assert.are.equal("次のタスク", data.sections[config.sections.NEXT][1].task.content)

					local todo_path = data_dir .. "/todo.md"
					io_mod.write_todo_file(todo_path, data)
					local headings = vim.tbl_filter(function(line)
						return line:match("^## ") ~= nil
					end, vim.fn.readfile(todo_path))
					assert.are.same({ "## Today", "## Next", "## Waiting", "## Someday" }, headings)
				end
			)

			-- 重複したままの名前を「前回の名前」として覚えると、設定を直した後も
			-- 1つの見出しが2つのキーの別名になり続ける。
			it("前回の名前として記憶するのは差し戻した後の名前", function()
				setup_and_capture({ TODAY = "やること", NEXT = "やること" })

				local last = require("gtodo-md.state").read_last_sections()
				assert.are.equal(config.default_sections.TODAY, last.TODAY)
				assert.are.equal(config.default_sections.NEXT, last.NEXT)
			end)
		end)
	end)
end)
