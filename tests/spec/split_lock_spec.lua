-- #92 回帰テスト: split ロックが行番号ベースでゾンビ化する不具合。
--
-- ポップアップ表示中に(他の場所での編集で)行が挿入・削除されると、旧実装は
-- ロックキーの行番号がズレたままになり、(a) 無関係な別の行がそのズレた行番号を
-- 引き継いだ場合に誤ってブロックされる、(b) BufWipeout以外の方法でポップアップが
-- 閉じられるとロックが永久に残る、という2つの問題があった。
--
-- 修正: タスク行(チェックボックス行)はタスクの一意なid(task.lua)をロックキーに
-- 使うことで行番号のズレに影響されないようにし、idを持たない行(素のリスト項目)は
-- extmark発行後はextmarkの現在位置を正として解決する。ロック解放もBufWipeoutと
-- WinClosedの両方から行う。

local split_mod = require("gtodo-md.ui.split")

describe("split.split_current_task のロック機構 (#92)", function()
	local buf, original_win, original_ui_input

	before_each(function()
		original_ui_input = vim.ui.input
		vim.ui.input = function(_, on_confirm)
			on_confirm("") -- タグ無しでプレーン分割
		end

		original_win = vim.api.nvim_get_current_win()
		buf = vim.api.nvim_create_buf(true, false)
		vim.bo[buf].modifiable = true
		vim.api.nvim_set_current_buf(buf)
	end)

	after_each(function()
		vim.ui.input = original_ui_input
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if w ~= original_win and vim.api.nvim_win_is_valid(w) then
				pcall(vim.api.nvim_win_close, w, true)
			end
		end
		if buf and vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end)

	local function open_split_at(row)
		vim.api.nvim_set_current_win(original_win)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_win_set_cursor(0, { row, 0 })
		split_mod.split_current_task()
	end

	local function open_split_and_capture_notify(row)
		local captured = {}
		local original_notify = vim.notify
		vim.notify = function(msg)
			table.insert(captured, msg)
		end
		open_split_at(row)
		vim.notify = original_notify
		return captured
	end

	local function was_blocked(captured)
		for _, msg in ipairs(captured) do
			if msg:find("already active", 1, true) then
				return true
			end
		end
		return false
	end

	it(
		"タスク行はidでロックされ、上に行が挿入され行番号がズレても無関係な行は誤ってブロックされない",
		function()
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] Task A", "- [ ] Task B" })

			open_split_at(1) -- Task A の split を開始(idが新規発行される)

			-- Task A の上に無関係な行を挿入して行番号をズラす
			vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "- [ ] Task Z" })
			-- バッファ: 1:Task Z, 2:Task A(split中), 3:Task B

			-- 行1(Task Z、無関係)は誤ってブロックされないはず
			local captured_z = open_split_and_capture_notify(1)
			assert.is_false(
				was_blocked(captured_z),
				"無関係なTask Zがブロックされた: " .. vim.inspect(captured_z)
			)

			-- 行2(Task Aがズレた後の実際の位置)は正しくブロックされるはず
			local captured_a = open_split_and_capture_notify(2)
			assert.is_true(
				was_blocked(captured_a),
				"ズレた後のTask Aがブロックされなかった: " .. vim.inspect(captured_a)
			)
		end
	)

	it(
		"チェックボックスの無い行はextmarkの現在位置を正としてロックが解決される",
		function()
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- Note A", "- Note B" })

			open_split_at(1) -- Note A の split を開始(idの概念が無いためrow/extmarkベース)

			-- Note A の上に無関係な行を挿入して行番号をズラす
			vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "- Note Z" })
			-- バッファ: 1:Note Z, 2:Note A(split中), 3:Note B

			local captured_z = open_split_and_capture_notify(1)
			assert.is_false(
				was_blocked(captured_z),
				"無関係なNote Zがブロックされた: " .. vim.inspect(captured_z)
			)

			local captured_a = open_split_and_capture_notify(2)
			assert.is_true(
				was_blocked(captured_a),
				"ズレた後のNote Aがブロックされなかった: " .. vim.inspect(captured_a)
			)
		end
	)

	it("WinClosedのみでもロックが解放される(BufWipeoutに依存しない)", function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] Task A" })
		local wins_before = vim.api.nvim_list_wins()

		open_split_at(1)

		local scratch_win
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local pre_existing = false
			for _, wb in ipairs(wins_before) do
				if wb == w then
					pre_existing = true
					break
				end
			end
			if not pre_existing then
				scratch_win = w
			end
		end
		assert.is_not_nil(scratch_win, "ポップアップウィンドウが見つからない")

		-- BufWipeoutが発火しない状況を模擬する(bufhidden=wipeを無効化してから閉じる)。
		-- WinClosed単体でロックが解放されることを検証したい。
		local scratch_buf = vim.api.nvim_win_get_buf(scratch_win)
		vim.bo[scratch_buf].bufhidden = ""

		vim.api.nvim_win_close(scratch_win, true)

		local captured = open_split_and_capture_notify(1)
		assert.is_false(
			was_blocked(captured),
			"WinClosedで解放されず、ロックが残っている: " .. vim.inspect(captured)
		)
	end)
end)
