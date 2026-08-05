local logic_mod = require("gtodo-md.logic")
local task_mod = require("gtodo-md.task")

-- #83 回帰テスト: append_to_history がディスクを直読みして
-- 開いているバッファの未保存内容を上書き消失させないことを確認する。

-- serialize が末尾に id:XXXXXX タグをランダム発行して付与するため、
-- 行の完全一致ではなく前方一致(id:タグを除く)で存在確認する。
local function contains_line_prefix(lines, prefix)
	for _, line in ipairs(lines) do
		if line == prefix or line:match("^" .. vim.pesc(prefix) .. " id:%x+$") then
			return true
		end
	end
	return false
end

describe("logic.append_to_history", function()
	-- パスはテストごとに変える。io.lua は「読んだ時点のディスク」をパス単位で
	-- 覚えており(並行更新の検出用)、同じパスを使い回すと前のテストの記録が
	-- 次のテストへ持ち越されて、外部からの作り直しを他プロセスの割り込みと
	-- 判定してしまう。
	local done_path

	before_each(function()
		done_path = vim.fn.tempname() .. "_done.md"
	end)

	after_each(function()
		vim.fn.delete(done_path)
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == done_path then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
	end)

	it(
		"ファイルが存在しない場合、ヘッダーとセクションを作成してタスクを追記する",
		function()
			local task = task_mod.parse("- [x] タスクA done:2025-01-01")
			logic_mod.append_to_history(done_path, "Done", "2025-01", { task })

			local lines = vim.fn.readfile(done_path)
			assert.are.same("# Done", lines[1])
			assert.is_true(vim.tbl_contains(lines, "## 2025-01"))
			assert.is_true(contains_line_prefix(lines, "- [x] タスクA done:2025-01-01"))
		end
	)

	it(
		"バッファが開いていて未保存の編集がある場合、その内容を失わずに追記する (#83)",
		function()
			vim.fn.writefile({ "# Done", "", "## 2025-01", "" }, done_path)

			-- バッファを開いて未保存の手動編集を加える
			vim.cmd("edit " .. vim.fn.fnameescape(done_path))
			local buf = vim.api.nvim_get_current_buf()
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			table.insert(lines, "- [x] 手動で書いた未保存タスク")
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			assert.is_true(vim.bo[buf].modified)

			local task = task_mod.parse("- [x] 自動処理タスク done:2025-01-02")
			logic_mod.append_to_history(done_path, "Done", "2025-01", { task })

			local after_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			assert.is_true(
				vim.tbl_contains(after_lines, "- [x] 手動で書いた未保存タスク"),
				"手動編集分の未保存内容が失われた"
			)
			assert.is_true(
				contains_line_prefix(after_lines, "- [x] 自動処理タスク done:2025-01-02"),
				"自動処理で追記したタスクが見当たらない"
			)

			vim.cmd("bdelete! " .. buf)
		end
	)
end)
