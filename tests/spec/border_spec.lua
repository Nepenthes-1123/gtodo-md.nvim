-- config.border: このプラグインが開くフローティングウィンドウの罫線スタイル。
--
-- 以前は todo/inbox/done/cancelled のフロート・Queue・カンバンの各列・タスク分割の
-- ポップアップの4箇所で "rounded" を直書きしていた。
--
-- 既定の "auto" は「ユーザーが設定している項目があればそちらを優先し、無ければ
-- こちらで見た目を用意する」という方針で次の順に解決する:
--   1. setup({ border = ... }) に具体的な値があればそれ
--   2. Neovim 全体の 'winborder' が設定されていればそれに委ねる
--      (nvim_open_win へ border を渡さない。渡すと 'winborder' を上書きしてしまう)
--   3. どちらも無ければ "rounded"
--
-- カンバンは罫線が左右に消費する幅をレイアウト計算へ織り込んでいる(#151/#154)ため、
-- 実際に効く罫線(effective_border)に消費幅の見積りが追従することも確認する。

local config = require("gtodo-md.config")

-- nvim_win_get_config は罫線ありのプリセットを8要素の文字配列として返し、
-- 罫線なしのときだけ文字列 "none" を返す(実測)。
local function border_of(win)
	return vim.api.nvim_win_get_config(win).border
end

local function first_float_win()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			return win
		end
	end
	return nil
end

describe("config.border", function()
	local data_dir
	local orig_columns, orig_lines
	local saved_notify

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		vim.fn.writefile({ "# Inbox", "" }, data_dir .. "/inbox.md")
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 期限付きタスク due:2030-01-01 id:aaa111",
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
		saved_notify = vim.notify
	end)

	after_each(function()
		vim.notify = saved_notify
		require("gtodo-md.ui.kanban").close_kanban()
		require("gtodo-md.ui.float").close_current_float()
		vim.o.columns, vim.o.lines = orig_columns, orig_lines
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		config.setup({ data_dir = data_dir }) -- 次のテストへ持ち越さない
		vim.fn.delete(data_dir, "rf")
	end)

	describe("解決順", function()
		local saved_global_winborder

		before_each(function()
			saved_global_winborder = vim.o.winborder
		end)

		after_each(function()
			vim.o.winborder = saved_global_winborder
		end)

		it("既定は auto", function()
			config.setup({ data_dir = data_dir })
			assert.are.same("auto", config.get("border"))
		end)

		it("プラグインの指定があれば 'winborder' より優先する", function()
			vim.o.winborder = "double"
			config.setup({ data_dir = data_dir, border = "single" })
			assert.are.same("single", config.resolve_border())
			assert.are.same("single", config.effective_border())
		end)

		-- border を明示すると 'winborder' を上書きしてしまうため、委ねる場合は
		-- nvim_open_win へ border を渡さない(= nil)必要がある。
		it("プラグイン未指定で 'winborder' があれば border を渡さず委ねる", function()
			vim.o.winborder = "double"
			config.setup({ data_dir = data_dir })
			assert.is_nil(config.resolve_border(), "border を明示して 'winborder' を上書きしている")
			assert.are.same("double", config.effective_border())
		end)

		it("どちらも未指定なら rounded", function()
			vim.o.winborder = ""
			config.setup({ data_dir = data_dir })
			assert.are.same("rounded", config.resolve_border())
			assert.are.same("rounded", config.effective_border())
		end)

		it("プリセット名で上書きできる", function()
			config.setup({ data_dir = data_dir, border = "double" })
			assert.are.same("double", config.get("border"))
		end)

		it("8要素のカスタム配列は検証せずそのまま通す", function()
			local custom = { "+", "-", "+", "|", "+", "-", "+", "|" }
			config.setup({ data_dir = data_dir, border = custom })
			assert.are.same(custom, config.get("border"))
		end)

		-- 素通しにすると nvim_open_win が例外を投げ、フロートを開こうとするたびに
		-- 生のエラーが表面化する(ui/float.lua は pcall していない)。
		it("不正な値は既定へ差し戻し、理由を通知する", function()
			local notified
			vim.notify = function(msg, level)
				if level == vim.log.levels.ERROR then
					notified = tostring(msg)
				end
			end

			config.setup({ data_dir = data_dir, border = "roundedd" })

			assert.are.same("auto", config.get("border"))
			assert.is_truthy(notified, "不正な border が黙って差し戻されている")
			assert.is_truthy(notified:find("border", 1, true), "想定外の通知: " .. tostring(notified))
		end)
	end)

	describe("フローティングウィンドウへの反映", function()
		it("todo フロートの罫線に反映される", function()
			config.setup({ data_dir = data_dir, border = "none" })
			require("gtodo-md.ui.float").open_todo_float()
			assert.are.same("none", border_of(first_float_win()))
		end)

		it("プラグイン未指定なら 'winborder' の設定がそのまま効く", function()
			local saved = vim.o.winborder
			vim.o.winborder = "none"
			config.setup({ data_dir = data_dir })
			require("gtodo-md.ui.float").open_todo_float()
			local got = border_of(first_float_win())
			vim.o.winborder = saved
			assert.are.same("none", got, "'winborder' がプラグイン側の明示指定で上書きされている")
		end)

		it("Queue の罫線に反映される", function()
			config.setup({ data_dir = data_dir, border = "none" })
			require("gtodo-md.ui.queue").open_queue()
			assert.are.same("none", border_of(first_float_win()))
		end)

		it("カンバンの各列の罫線に反映される", function()
			config.setup({ data_dir = data_dir, border = "none" })
			require("gtodo-md.ui.kanban").open_kanban()
			local checked = 0
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_config(win).relative ~= "" then
					assert.are.same("none", border_of(win))
					checked = checked + 1
				end
			end
			assert.is_true(checked > 0, "カンバンの列が1つも開いていない")
		end)
	end)

	describe("カンバンのレイアウトへの反映", function()
		it("_border_width は罫線なしを0、罫線ありを2として扱う", function()
			local kanban = require("gtodo-md.ui.kanban")
			assert.are.same(0, kanban._border_width("none"))
			assert.are.same(0, kanban._border_width(""))
			assert.are.same(0, kanban._border_width(nil))
			assert.are.same(0, kanban._border_width({ "", "", "", "", "", "", "", "" }))
			assert.are.same(2, kanban._border_width("rounded"))
			assert.are.same(2, kanban._border_width("double"))
			assert.are.same(2, kanban._border_width({ "+", "-", "+", "|", "+", "-", "+", "|" }))
			-- 判別できない指定は「消費する側」へ倒す(はみ出すより余白が余る方が安全)
			assert.are.same(2, kanban._border_width("shadow"))
		end)

		it("罫線なしのぶんだけ列を多く置ける", function()
			local kanban = require("gtodo-md.ui.kanban")
			-- 1列の消費幅は 20(+罫線) なので、幅66 では罫線ありで2列・なしで3列になる
			local with_border = kanban._compute_layout(5, 66, 40, 2)
			local without_border = kanban._compute_layout(5, 66, 40, 0)
			assert.are.same(2, with_border.visible_count)
			assert.are.same(3, without_border.visible_count)
		end)

		it("罫線なしでも消費幅は領域幅を超えない", function()
			local kanban = require("gtodo-md.ui.kanban")
			local violations = {}
			for avail_width = 20, 400 do
				local layout = kanban._compute_layout(5, avail_width, 40, 0)
				local used = layout.visible_count * layout.col_width + 1 * (layout.visible_count - 1)
				if used > avail_width then
					table.insert(violations, string.format("avail=%d used=%d", avail_width, used))
				end
			end
			assert.are.same({}, violations, "罫線なしの見積りで列がはみ出している")
		end)
	end)
end)
