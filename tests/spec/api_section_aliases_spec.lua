-- api.get_stats() が config.section_aliases を見ていないことの回帰テスト。
--
-- get_stats() は todo.md の "## Today" セクション配下の未完了タスク数を数えるが、
-- 現状は config.sections.TODAY(現在のカスタム名)にしかマッチしない正規表現を
-- 使っている。config.section_aliases(key) は「現在のカスタム名・デフォルト名・
-- 前回のsetup()で使われていた名前」の最大3つを優先順に返し、validate.lua/io.lua は
-- 既にこれを使って複数の名前を許容している。get_stats() だけが追従していないため、
-- setup({ sections = { TODAY = "今日" } }) 直後、まだ todo.md を保存し直していない
-- 場合(見出しはまだ "## Today" のまま)、Today件数が実際には存在するのに0のまま
-- 返ってしまう。

describe("api.get_stats: config.section_aliasesへの追従", function()
	local data_dir
	local api_mod
	local config

	local function reload_modules()
		for _, k in ipairs({
			"gtodo-md.api",
			"gtodo-md.daily",
			"gtodo-md.config",
			"gtodo-md.lock",
			"gtodo-md.logic",
		}) do
			package.loaded[k] = nil
		end
		config = require("gtodo-md.config")
		api_mod = require("gtodo-md.api")
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")

		reload_modules()
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	it(
		"セクション名をカスタム化した直後、見出しがまだデフォルト名(## Today)のままのtodo.mdでもToday件数を数える",
		function()
			-- カスタム名 "今日" へ変更する。section_aliases("TODAY") は
			-- { "今日", "Today" } を返すはずで、デフォルト名の見出しも
			-- 引き続き受理されなければならない。
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })

			vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
			-- 見出しはまだ前回(デフォルト)の "## Today" のまま(保存し直していない状態を再現)
			vim.fn.writefile({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 未完了todoタスク",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}, data_dir .. "/todo.md")

			local stats = api_mod.get_stats()

			assert.are.same(1, stats.today, "section_aliasesに追従していれば1になるはず")
		end
	)
end)
