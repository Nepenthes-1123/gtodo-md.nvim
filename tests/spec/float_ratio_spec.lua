-- #151 回帰テスト: todo/inbox/done/cancelledのフロート・Queue・カンバンの
-- 高さ/横幅を割合(vim.o.columns/vim.o.lines に対する比率)で設定できるようにする。
--
-- 設計上の要件:
-- - todo/inbox/done/cancelled のフロートと Queue は float_width_ratio/float_height_ratio
--   (既定0.8)を共有する。Queue にあった絶対値上限(min(..., 80列))は廃止する。
-- - カンバンは列数を確保するためになるべく画面全体を使いたいという目的の違いから、
--   float_width_ratio/float_height_ratio とは独立した kanban_width_ratio/kanban_height_ratio
--   (既定はより広め)を持つ。float_width_ratio を変えてもカンバンの列幅は変化しない。

local config = require("gtodo-md.config")

describe("config: float/kanban 用の比率設定 (#151)", function()
	describe("デフォルト値", function()
		it("float_width_ratio/float_height_ratioの既定値は0.8", function()
			assert.are.equal(0.8, config.get("float_width_ratio"))
			assert.are.equal(0.8, config.get("float_height_ratio"))
		end)

		it("kanban_width_ratioの既定値は単一フロートより広く、kanban_height_ratioは0.8", function()
			assert.is_true(config.get("kanban_width_ratio") > config.get("float_width_ratio"))
			assert.are.equal(0.8, config.get("kanban_height_ratio"))
		end)
	end)

	describe("setup()での上書き", function()
		local data_dir

		before_each(function()
			data_dir = vim.fn.tempname()
			vim.fn.mkdir(data_dir .. "/projects", "p")
		end)

		after_each(function()
			config.setup({ data_dir = data_dir }) -- 次のテストへ影響しないよう既定に戻す
			vim.fn.delete(data_dir, "rf")
		end)

		it("float_width_ratio/float_height_ratioをキー単位で上書きできる", function()
			config.setup({ data_dir = data_dir, float_width_ratio = 0.5, float_height_ratio = 0.6 })
			assert.are.equal(0.5, config.get("float_width_ratio"))
			assert.are.equal(0.6, config.get("float_height_ratio"))
		end)

		it("kanban_width_ratio/kanban_height_ratioをキー単位で上書きできる", function()
			config.setup({ data_dir = data_dir, kanban_width_ratio = 0.95, kanban_height_ratio = 0.7 })
			assert.are.equal(0.95, config.get("kanban_width_ratio"))
			assert.are.equal(0.7, config.get("kanban_height_ratio"))
		end)

		it("一部だけ上書きしても他のキーは既定値のまま残る", function()
			config.setup({ data_dir = data_dir, float_width_ratio = 0.5 })
			assert.are.equal(0.5, config.get("float_width_ratio"))
			assert.are.equal(0.8, config.get("float_height_ratio"))
			assert.are.equal(0.9, config.get("kanban_width_ratio"))
			assert.are.equal(0.8, config.get("kanban_height_ratio"))
		end)
	end)
end)

describe("ui.float.open_float の比率設定 (#151)", function()
	local data_dir, path

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		path = data_dir .. "/todo.md"
		vim.fn.writefile({ "# Todo", "" }, path)
	end)

	after_each(function()
		require("gtodo-md.ui.float").close_current_float()
		config.setup({ data_dir = data_dir })
		vim.fn.delete(data_dir, "rf")
	end)

	it("float_width_ratio/float_height_ratioに応じたウィンドウサイズで開く", function()
		config.setup({ data_dir = data_dir, float_width_ratio = 0.5, float_height_ratio = 0.4 })

		local float = require("gtodo-md.ui.float")
		local _, win = float.open_float(path, "Todo")
		local win_config = vim.api.nvim_win_get_config(win)

		assert.are.equal(math.floor(vim.o.columns * 0.5), win_config.width)
		assert.are.equal(math.floor(vim.o.lines * 0.4), win_config.height)
	end)
end)

describe("ui.queue.open_queue の比率設定 (#151)", function()
	local data_dir, orig_columns, orig_lines

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] queue用タスク due:2026-08-26",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, data_dir .. "/todo.md")
		vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")

		orig_columns, orig_lines = vim.o.columns, vim.o.lines
		vim.o.columns = 200
	end)

	after_each(function()
		require("gtodo-md.ui.float").close_current_float()
		config.setup({ data_dir = data_dir })
		vim.o.columns, vim.o.lines = orig_columns, orig_lines
		vim.fn.delete(data_dir, "rf")
	end)

	it("float_width_ratioに応じて幅が変わり、80列の絶対値上限は存在しない", function()
		config.setup({ data_dir = data_dir, float_width_ratio = 0.95 })

		local queue = require("gtodo-md.ui.queue")
		queue.open_queue("due")

		local win = vim.api.nvim_get_current_win()
		local win_config = vim.api.nvim_win_get_config(win)

		local expected_width = math.floor(vim.o.columns * 0.95)
		assert.are.equal(expected_width, win_config.width)
		assert.is_true(
			win_config.width > 80,
			"80列の絶対値上限が復活している可能性がある: width=" .. win_config.width
		)
	end)
end)

describe("ui.kanban の比率設定 (#151)", function()
	local data_dir, orig_columns, orig_lines

	local function list_float_wins()
		local wins = {}
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
			if ok and cfg.relative == "editor" then
				table.insert(wins, w)
			end
		end
		return wins
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, data_dir .. "/todo.md")
		vim.fn.writefile({ "# Done", "" }, data_dir .. "/done.md")

		orig_columns, orig_lines = vim.o.columns, vim.o.lines
		vim.o.columns = 200
		vim.o.lines = 50
	end)

	after_each(function()
		require("gtodo-md.ui.kanban").close_kanban()
		config.setup({ data_dir = data_dir })
		vim.o.columns, vim.o.lines = orig_columns, orig_lines
		vim.fn.delete(data_dir, "rf")
	end)

	it("kanban_width_ratioを大きくすると小さくするより表示列数が増える", function()
		local kanban = require("gtodo-md.ui.kanban")

		config.setup({ data_dir = data_dir, kanban_width_ratio = 0.3 })
		kanban.open_kanban()
		local narrow_count = #list_float_wins()
		kanban.close_kanban()

		config.setup({ data_dir = data_dir, kanban_width_ratio = 0.95 })
		kanban.open_kanban()
		local wide_count = #list_float_wins()
		kanban.close_kanban()

		assert.is_true(
			wide_count > narrow_count,
			string.format(
				"wide=%d narrow=%d: 比率を上げても表示列数が増えていない",
				wide_count,
				narrow_count
			)
		)
	end)

	it("float_width_ratioを変えてもカンバンの列幅は変化しない(独立設定)", function()
		local kanban = require("gtodo-md.ui.kanban")

		config.setup({ data_dir = data_dir, float_width_ratio = 0.3, kanban_width_ratio = 0.9 })
		kanban.open_kanban()
		local width1 = vim.api.nvim_win_get_config(list_float_wins()[1]).width
		kanban.close_kanban()

		config.setup({ data_dir = data_dir, float_width_ratio = 0.95, kanban_width_ratio = 0.9 })
		kanban.open_kanban()
		local width2 = vim.api.nvim_win_get_config(list_float_wins()[1]).width
		kanban.close_kanban()

		assert.are.equal(
			width1,
			width2,
			"float_width_ratioの変更がkanbanの列幅に影響してしまっている"
		)
	end)

	it("kanban_height_ratioに応じて列の高さが変わる", function()
		local kanban = require("gtodo-md.ui.kanban")

		config.setup({ data_dir = data_dir, kanban_height_ratio = 0.5 })
		kanban.open_kanban()
		local height = vim.api.nvim_win_get_config(list_float_wins()[1]).height
		kanban.close_kanban()

		assert.are.equal(math.max(10, math.floor(vim.o.lines * 0.5)), height)
	end)
end)
