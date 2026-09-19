-- config.winborder: このプラグインが開くフローティングウィンドウの罫線スタイル。
--
-- 以前は todo/inbox/done/cancelled のフロート・Queue・カンバンの各列・タスク分割の
-- ポップアップの4箇所で "rounded" を直書きしていた。Neovim 全体の 'winborder' では
-- なくプラグイン固有のオプションを見るのは、nvim_open_win の border 明示指定が
-- 'winborder' を上書きする仕様上、両者を混ぜると「どちらが効くのか」が利用者から
-- 見て不透明になるため。
--
-- カンバンは罫線が左右に消費する幅をレイアウト計算へ織り込んでいる(#151/#154)ため、
-- 罫線を消す設定にしたときに消費幅の見積りも追従することを併せて確認する。

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

describe("config.winborder", function()
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

	describe("設定値", function()
		it("既定は rounded(従来の見た目を維持する)", function()
			config.setup({ data_dir = data_dir })
			assert.are.same("rounded", config.get("winborder"))
		end)

		it("プリセット名で上書きできる", function()
			config.setup({ data_dir = data_dir, winborder = "double" })
			assert.are.same("double", config.get("winborder"))
		end)

		it("8要素のカスタム配列は検証せずそのまま通す", function()
			local custom = { "+", "-", "+", "|", "+", "-", "+", "|" }
			config.setup({ data_dir = data_dir, winborder = custom })
			assert.are.same(custom, config.get("winborder"))
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

			config.setup({ data_dir = data_dir, winborder = "roundedd" })

			assert.are.same("rounded", config.get("winborder"))
			assert.is_truthy(notified, "不正な winborder が黙って差し戻されている")
			assert.is_truthy(notified:find("winborder", 1, true), "想定外の通知: " .. tostring(notified))
		end)
	end)

	describe("フローティングウィンドウへの反映", function()
		it("todo フロートの罫線に反映される", function()
			config.setup({ data_dir = data_dir, winborder = "none" })
			require("gtodo-md.ui.float").open_todo_float()
			assert.are.same("none", border_of(first_float_win()))
		end)

		it("Queue の罫線に反映される", function()
			config.setup({ data_dir = data_dir, winborder = "none" })
			require("gtodo-md.ui.queue").open_queue()
			assert.are.same("none", border_of(first_float_win()))
		end)

		it("カンバンの各列の罫線に反映される", function()
			config.setup({ data_dir = data_dir, winborder = "none" })
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
