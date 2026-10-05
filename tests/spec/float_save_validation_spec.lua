-- #164 の回帰テスト。
-- ui/float.lua の WinLeave 自動保存は autocmd のコールバック内で :write を実行する。
-- autocmd は既定でネストしないため、この :write では BufWritePre が発火せず、
-- autocmds.lua の保存時バリデーション(必須セクション・必須ヘッダー・履歴セクション・
-- プロジェクトのフロントマター)を一切通らずにディスクへ書き込まれていた。
-- フロートはこれらのファイルを編集する主な手段なので、実際の利用では保護がほぼ効いていなかった。

local config = require("gtodo-md.config")

describe("ui.float の WinLeave 自動保存", function()
	local float, project_mod
	local data_dir, proj_path
	local saved_notify, notifications

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })
		require("gtodo-md").setup_autocmds()
		float = require("gtodo-md.ui.float")
		project_mod = require("gtodo-md.ui.project")

		saved_notify = vim.notify
		notifications = {}
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = tostring(msg), level = level })
		end

		project_mod.create_project_file("demo")
		proj_path = data_dir .. "/projects/demo.md"
	end)

	after_each(function()
		vim.notify = saved_notify
		float.close_current_float()
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find(data_dir, 1, true) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	local function notified_error()
		for _, n in ipairs(notifications) do
			if n.level == vim.log.levels.ERROR then
				return n.msg
			end
		end
		return nil
	end

	-- フロートで開いて edit を適用し、通常のウィンドウへ戻る。
	-- WinLeave 内で予約されるクローズ処理(vim.schedule)まで流してから返す。
	local function edit_in_float_and_leave(edit)
		local buf, win = float.open_float(proj_path, "Project: demo")
		edit(buf)
		vim.cmd("wincmd p")
		vim.wait(20)
		return buf, win
	end

	local function remove_line(buf, prefix)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		for i, line in ipairs(lines) do
			if line:find(prefix, 1, true) == 1 then
				vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
				return
			end
		end
		error("行が見つからない: " .. prefix)
	end

	local function disk_has(prefix)
		for _, line in ipairs(vim.fn.readfile(proj_path)) do
			if line:find(prefix, 1, true) == 1 then
				return true
			end
		end
		return false
	end

	it("保存時バリデーションに通らない編集はディスクへ書き込まない", function()
		edit_in_float_and_leave(function(buf)
			remove_line(buf, "tag:")
		end)

		assert.is_true(disk_has("tag:"), "フロントマターを壊した内容がディスクへ書き込まれた")
	end)

	it(
		"保存できなかったときは理由を通知し、編集を失わないようウィンドウを残す",
		function()
			local buf, win = edit_in_float_and_leave(function(b)
				remove_line(b, "tag:")
			end)

			local err = notified_error()
			assert.is_truthy(err, "保存の失敗が通知されていない(握り潰されている)")
			assert.are.same(
				1,
				err:find("[gtodo-md]", 1, true),
				"バリデーションの理由が先頭に来ていない(autocmd の呼び出し経路が残っている): "
					.. tostring(err)
			)
			assert.is_true(vim.api.nvim_win_is_valid(win), "保存できなかったのにウィンドウを閉じた")
			assert.is_true(
				vim.bo[buf].modified,
				"保存できなかった編集が未保存として残っていない"
			)
		end
	)

	it("バリデーションに通る編集は保存してウィンドウを閉じる", function()
		local _, win = edit_in_float_and_leave(function(buf)
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			table.insert(lines, "追記した本文")
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		end)

		assert.is_true(disk_has("追記した本文"), "編集内容が保存されていない")
		assert.is_nil(notified_error(), "正常系でエラー通知が出ている: " .. tostring(notified_error()))
		assert.is_false(vim.api.nvim_win_is_valid(win), "保存できたのにウィンドウが残っている")
	end)

	-- nested にすると、ユーザー側の BufWritePre/BufWritePost(保存時フォーマット等)も
	-- 自動保存で走るようになる。編集していないのに走らせないよう、変更が無ければ書かない。
	it("編集していなければ書き込まない", function()
		local writes = 0
		local probe = vim.api.nvim_create_augroup("GtodoFloatSaveProbe", { clear = true })
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = probe,
			pattern = "*",
			callback = function()
				writes = writes + 1
			end,
		})

		local _, win = edit_in_float_and_leave(function() end)
		vim.api.nvim_del_augroup_by_id(probe)

		assert.are.same(0, writes, "編集していないのに書き込んでいる")
		assert.is_false(
			vim.api.nvim_win_is_valid(win),
			"通常のウィンドウへ戻ったのにフロートが残っている"
		)
	end)
end)
