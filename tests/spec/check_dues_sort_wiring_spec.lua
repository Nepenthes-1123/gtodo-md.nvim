-- check_dues → sort_todo_file の配線パターンを固定する回帰テスト。
--
-- init.lua/daily.lua には「排他ロックを取り、check_dues を実行し、条件に応じて
-- sort_todo_file を呼ぶ」という同じ形の手順が複数箇所に個別配線されており、
-- ソートを行う条件が箇所ごとに微妙に異なる(simplify-sweepのアーキテクチャ監査で
-- 判明)。将来これらを1つの共通関数へ統合する際、この条件差を気づかず均してしまう
-- 事故を防ぐため、現状の挙動をそれぞれ個別に固定しておく。
--
--   - handle_buf_enter: sortするかどうかは「todo.mdを開いているか」だけで決まり、
--     check_dues自体が変化を起こしたかどうかは見ない(inbox.md表示中の昇格は
--     sortされないまま残る)。
--   - check_daily_rollover: sortするかどうかはtodo_changed(move_completed_tasksまたは
--     check_dues のいずれかが変化を起こしたか)で決まる。
--   - M.sort_and_check_dues (手動コマンド): 変化の有無に関わらず常にsortする。

local function find_line_index(lines, prefix)
	for i, line in ipairs(lines) do
		if line:match("^" .. vim.pesc(prefix)) then
			return i
		end
	end
	return nil
end

describe("check_dues → sort_todo_file の配線パターン", function()
	local data_dir
	local inbox_path
	local todo_path
	local today
	local tomorrow

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")

		for _, k in ipairs({ "gtodo-md", "gtodo-md.daily", "gtodo-md.config", "gtodo-md.lock", "gtodo-md.logic" }) do
			package.loaded[k] = nil
		end

		inbox_path = data_dir .. "/inbox.md"
		todo_path = data_dir .. "/todo.md"
		today = os.date("%Y-%m-%d")
		tomorrow = os.date("%Y-%m-%d", os.time() + 86400)
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	it(
		"handle_buf_enter: inbox.md表示中はcheck_duesで昇格があってもtodo.mdをソートしない",
		function()
			local main_mod = require("gtodo-md")
			local config = require("gtodo-md.config")
			local state_mod = require("gtodo-md.state")

			config.setup({ data_dir = data_dir })
			state_mod.write_last_opened(today)

			vim.fn.writefile({ "# Inbox", "", "- [ ] 昇格タスク due:" .. today }, inbox_path)
			vim.fn.writefile({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 既存タスク due:" .. tomorrow,
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}, todo_path)

			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, inbox_path)
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("edit!")
			end)

			main_mod.handle_buf_enter(buf)

			local todo_lines = vim.fn.readfile(todo_path)
			local idx_existing = find_line_index(todo_lines, "- [ ] 既存タスク")
			local idx_promoted = find_line_index(todo_lines, "- [ ] 昇格タスク")
			assert.is_not_nil(
				idx_promoted,
				"昇格タスクがtodo.mdに見当たらない: " .. vim.inspect(todo_lines)
			)
			assert.is_true(
				idx_existing < idx_promoted,
				"inbox.md表示中にtodo.mdがソートされてしまった(現状の仕様と異なる): "
					.. vim.inspect(todo_lines)
			)

			vim.api.nvim_buf_delete(buf, { force = true })
		end
	)

	it("handle_buf_enter: todo.md表示中はcheck_duesの変化が無くても常にソートされる", function()
		local main_mod = require("gtodo-md")
		local config = require("gtodo-md.config")
		local state_mod = require("gtodo-md.state")

		config.setup({ data_dir = data_dir })
		state_mod.write_last_opened(today)

		-- inboxにdueタスクは無い(check_dues自体は何も変化させない)
		vim.fn.writefile({ "# Inbox", "" }, inbox_path)
		-- todo.mdはあえて due の昇順を崩した並びで用意する
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 後のタスク due:" .. tomorrow,
			"- [ ] 先のタスク due:" .. today,
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, todo_path)

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, todo_path)
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("edit!")
		end)

		main_mod.handle_buf_enter(buf)

		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local idx_earlier, idx_later
		for i, line in ipairs(lines) do
			if line:match("^%- %[ %] 先のタスク") then
				idx_earlier = i
			elseif line:match("^%- %[ %] 後のタスク") then
				idx_later = i
			end
		end
		assert.is_not_nil(idx_earlier, "先のタスクが見当たらない: " .. vim.inspect(lines))
		assert.is_true(
			idx_earlier < idx_later,
			"todo.md表示中なのにcheck_duesの変化が無いことを理由にソートがスキップされた: "
				.. vim.inspect(lines)
		)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it(
		"check_daily_rollover: 完了タスクの繰り込みが無くてもcheck_duesの変化だけでsort_todo_fileが実行される",
		function()
			local daily_mod = require("gtodo-md.daily")
			local config = require("gtodo-md.config")
			local state_mod = require("gtodo-md.state")
			local yesterday = os.date("%Y-%m-%d", os.time() - 86400)

			config.options = { data_dir = data_dir }
			state_mod.write_last_opened(yesterday)

			vim.fn.writefile({ "# Inbox", "", "- [ ] 昇格タスク due:" .. today }, inbox_path)
			vim.fn.writefile({
				"# Todo",
				"",
				"## Today",
				"",
				"- [ ] 既存タスク due:" .. tomorrow,
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}, todo_path)
			vim.fn.writefile({ "# Done", "" }, data_dir .. "/done.md")

			local rolled_over = daily_mod.check_daily_rollover()
			assert.is_true(rolled_over)

			local todo_lines = vim.fn.readfile(todo_path)
			local idx_existing = find_line_index(todo_lines, "- [ ] 既存タスク")
			local idx_promoted = find_line_index(todo_lines, "- [ ] 昇格タスク")
			assert.is_not_nil(
				idx_promoted,
				"昇格タスクがtodo.mdに見当たらない: " .. vim.inspect(todo_lines)
			)
			assert.is_true(
				idx_promoted < idx_existing,
				"完了タスクの移動が無いためsort_todo_fileがスキップされた(check_duesだけの変化で走るべき): "
					.. vim.inspect(todo_lines)
			)
		end
	)

	it("M.sort_and_check_dues: check_duesの変化が無くても常にtodo.mdをソートする", function()
		local main_mod = require("gtodo-md")
		local config = require("gtodo-md.config")
		local state_mod = require("gtodo-md.state")

		config.setup({ data_dir = data_dir })
		state_mod.write_last_opened(today)

		vim.fn.writefile({ "# Inbox", "" }, inbox_path)
		vim.fn.writefile({
			"# Todo",
			"",
			"## Today",
			"",
			"- [ ] 後のタスク due:" .. tomorrow,
			"- [ ] 先のタスク due:" .. today,
			"",
			"## Next",
			"",
			"## Waiting",
			"",
			"## Someday",
			"",
		}, todo_path)

		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, todo_path)
		vim.api.nvim_set_current_buf(buf)
		vim.cmd("edit!")

		main_mod.sort_and_check_dues()

		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local idx_earlier, idx_later
		for i, line in ipairs(lines) do
			if line:match("^%- %[ %] 先のタスク") then
				idx_earlier = i
			elseif line:match("^%- %[ %] 後のタスク") then
				idx_later = i
			end
		end
		assert.is_not_nil(idx_earlier, "先のタスクが見当たらない: " .. vim.inspect(lines))
		assert.is_true(
			idx_earlier < idx_later,
			"sort_and_check_duesが変化の有無に関わらず常にソートする、という前提が崩れている: "
				.. vim.inspect(lines)
		)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)
end)
