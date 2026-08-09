-- 全体コードレビューで挙がった中〜低深刻度の指摘に対する回帰テスト。
-- それぞれ独立した不具合で共通の根本原因は無いため、1ファイルにまとめている。

local config = require("gtodo-md.config")
local task_mod = require("gtodo-md.task")

describe("レビュー指摘の回帰テスト", function()
	local data_dir
	local saved_data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		saved_data_dir = config.options.data_dir
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		config.options.data_dir = saved_data_dir
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	-- 指摘4: 対象月の見出しが「存在するか」しか見ておらず「位置」を見ていなかったため、
	-- 過去月の見出しが末尾でない場合にタスクが違う月の配下へ紛れ込んでいた。
	describe("logic.history.append_to_history の挿入位置", function()
		it("対象セクションが最後でない場合、そのセクションの末尾へ入る", function()
			local done_path = data_dir .. "/done.md"
			vim.fn.writefile({
				"# Done",
				"",
				"## 2026-07",
				"",
				"- [x] 7月の既存タスク",
				"",
				"## 2026-08",
				"",
				"- [x] 8月の既存タスク",
			}, done_path)

			require("gtodo-md.logic").append_to_history(
				done_path,
				"Done",
				"2026-07",
				{ task_mod.parse("- [x] 7月の遅延タスク") }
			)

			local lines = vim.fn.readfile(done_path)
			local idx_added, idx_aug
			for i, l in ipairs(lines) do
				if l:find("7月の遅延タスク", 1, true) then
					idx_added = i
				elseif l == "## 2026-08" then
					idx_aug = i
				end
			end

			assert.is_truthy(idx_added, "追記した行が見つからない")
			assert.is_truthy(idx_aug)
			assert.is_true(idx_added < idx_aug, "2026-08 の配下に紛れ込んでいる")
		end)

		it("対象セクションが最後なら従来どおり末尾へ追記される", function()
			local done_path = data_dir .. "/done.md"
			vim.fn.writefile({ "# Done", "", "## 2026-08", "", "- [x] 既存" }, done_path)

			require("gtodo-md.logic").append_to_history(
				done_path,
				"Done",
				"2026-08",
				{ task_mod.parse("- [x] 追加") }
			)

			local lines = vim.fn.readfile(done_path)
			assert.is_truthy(lines[#lines]:find("追加", 1, true))
		end)

		it("セクションが無ければ新規に見出しを作る", function()
			local done_path = data_dir .. "/done.md"
			vim.fn.writefile({ "# Done", "" }, done_path)

			require("gtodo-md.logic").append_to_history(
				done_path,
				"Done",
				"2026-09",
				{ task_mod.parse("- [x] 新規月") }
			)

			local lines = vim.fn.readfile(done_path)
			assert.is_true(vim.tbl_contains(lines, "## 2026-09"))
		end)
	end)

	-- 指摘9: 無アンカー検索だったため、本文中の "(B)" まで優先度としてハイライトしていた。
	describe("highlight._match_priority", function()
		local match = function(line)
			return select(2, require("gtodo-md.highlight")._match_priority(line))
		end

		it("チェックボックス直後の優先度は拾う", function()
			assert.are.equal("(A)", match("- [ ] (A) 重要なタスク"))
			assert.are.equal("(B)", match("  - [x] (B) 完了タスク"))
		end)

		it("本文中の (B) は拾わない", function()
			assert.is_nil(match("- [ ] Reply about grade (B) to teacher"))
		end)

		it("後ろにスペースが無い場合は拾わない(task.lua と同じ規則)", function()
			assert.is_nil(match("- [ ] (A)タスク"))
		end)

		it("タスク行でなければ拾わない", function()
			assert.is_nil(match("## (A) セクション見出し"))
		end)
	end)

	-- 指摘10: vim.json.encode の失敗が無通知で握り潰され、.state.json への
	-- 永続化が黙ってスキップされていた(すぐ下の atomic_write 失敗は通知しているのに非対称)。
	describe("utils の状態書き込み", function()
		it("JSON エンコードに失敗したら通知する", function()
			local notified = {}
			local saved_notify = vim.notify
			vim.notify = function(msg, level)
				table.insert(notified, { msg = msg, level = level })
			end

			-- 循環参照を含むテーブルは encode に失敗する
			local circular = {}
			circular.self = circular
			-- luacheck: ignore
			pcall(require("gtodo-md.utils").write_last_sections, circular)

			vim.notify = saved_notify

			assert.is_true(#notified > 0, "エンコード失敗が無通知で握り潰されている")
			assert.are.equal(vim.log.levels.ERROR, notified[1].level)
		end)
	end)

	-- 指摘8: open_float が WinLeave を無条件登録しており、同じファイルを開き直すたびに
	-- autocmd が蓄積していた(発火のたびに :write とウィンドウクローズが回数分走る)。
	describe("ui.float の WinLeave 登録", function()
		it("同じファイルを開き直しても autocmd が蓄積しない", function()
			local path = data_dir .. "/todo.md"
			vim.fn.writefile({ "# Todo", "" }, path)

			local float = require("gtodo-md.ui.float")
			local function count()
				local buf = vim.fn.bufadd(path)
				return #vim.api.nvim_get_autocmds({ event = "WinLeave", buffer = buf })
			end

			float.open_float(path, "Todo")
			local after_first = count()
			for _ = 1, 3 do
				float.open_float(path, "Todo")
			end

			assert.are.equal(after_first, count(), "開き直すたびに WinLeave が積み上がっている")
			float.close_current_float()
		end)
	end)

	-- 指摘6: サニタイズ結果が空文字になった場合に release_entry を呼ばずに中断しており、
	-- 分割ロックがリークして同じタスクの分割が再起動まで恒久的にブロックされていた。
	describe("split のロック解放", function()
		it("プロジェクトタグが空文字に正規化されても再度分割できる", function()
			local path = data_dir .. "/todo.md"
			vim.fn.writefile({ "# Todo", "", "## Today", "", "- [ ] 分割対象タスク" }, path)
			vim.cmd("edit " .. vim.fn.fnameescape(path))
			vim.api.nvim_win_set_cursor(0, { 5, 0 })

			local saved_input = vim.ui.input
			-- 記号のみ → sanitize_project_tag が空文字を返す
			vim.ui.input = function(_, on_confirm)
				on_confirm("...")
			end

			local notified = {}
			local saved_notify = vim.notify
			vim.notify = function(msg)
				table.insert(notified, tostring(msg))
			end

			local split = require("gtodo-md.ui.split")
			split.split_current_task()
			-- 2回目: ロックが漏れていれば "already active" で弾かれる
			vim.api.nvim_win_set_cursor(0, { 5, 0 })
			split.split_current_task()

			vim.ui.input = saved_input
			vim.notify = saved_notify

			for _, msg in ipairs(notified) do
				assert.is_nil(
					msg:lower():find("already active", 1, true),
					"ロックが解放されておらず2回目の分割がブロックされている: " .. msg
				)
			end
		end)
	end)

	-- 指摘7: Waiting 移動は vim.ui.input の待機中も row をクロージャに抱えたままで、
	-- その間に行がずれると無関係な行を削除していた。
	describe("editor の行の再同定", function()
		it("待機中に行がずれても、元の行テキストで対象を探し直す", function()
			local inbox_path = data_dir .. "/inbox.md"
			local todo_path = data_dir .. "/todo.md"
			vim.fn.writefile({ "# Inbox", "", "- [ ] 移動するタスク" }, inbox_path)
			vim.fn.writefile({
				"# Todo",
				"",
				"## " .. config.sections.TODAY,
				"",
				"## " .. config.sections.NEXT,
				"",
				"## " .. config.sections.WAITING,
				"",
				"## " .. config.sections.SOMEDAY,
				"",
			}, todo_path)

			vim.cmd("edit " .. vim.fn.fnameescape(inbox_path))
			local buf = vim.api.nvim_get_current_buf()
			local task = task_mod.parse("- [ ] 移動するタスク")
			local stale_row = 3

			-- 待機中に他の行が差し込まれ、対象が下へずれた状況を作る
			vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "- [ ] あとから割り込んだ行" })
			require("gtodo-md.io").record_stamp(inbox_path)

			require("gtodo-md.editor")._execute_move(task, stale_row, config.sections.TODAY)

			local remaining = table.concat(vim.fn.readfile(inbox_path), "\n")
			assert.is_truthy(
				remaining:find("あとから割り込んだ行", 1, true),
				"古い row を信じて無関係な行を削除している"
			)
			assert.is_nil(
				remaining:find("移動するタスク", 1, true),
				"対象タスクが削除されていない"
			)
		end)
	end)
end)
