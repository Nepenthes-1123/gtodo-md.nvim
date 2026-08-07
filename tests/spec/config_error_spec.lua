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
	end)
end)
