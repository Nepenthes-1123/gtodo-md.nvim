-- 定期タスクを作る。日次の整理(daily.check_daily_rollover のロックの中)から 1 日 1 回呼ばれる。
--
-- 定期タスクは、フロントマターに `type: recurring` と `repeat:` を書いたテンプレート
-- (templates/<name>.md。アーカイブしたものは含まない)。規則の読み取りと判定は logic/recurring.lua。
--
-- どの日まで確かめたかをテンプレートごとに .state.json (recurring) へ記録し、その日より後で
-- 今日までに当たる日のうち最後の 1 回分だけを作る(しばらく開かなかった後に同じタスクを溜めない)。
-- 記録の無いテンプレート(作ったばかり・復元したばかり)は今日の分だけを見る。
-- 相対の期日(due:+3d)は、作る日ではなくその回の日から数える(作るのが遅れても期日はずれない)。
--
-- 書く順序: inbox.md へ足してから記録する。記録が先だと、足す前に止まったときにその回が
-- 失われる。この順序なら止まっても次の整理で同じ回をもう一度作る(重複)だけで済む —
-- logic/write_pair.lua と同じ「消失より重複」の判断。.state.json が壊れていて記録できない
-- ときは、整理のたびに同じタスクを作ってしまうので作らない。
local M = {}

local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")
local logic = require("gtodo-md.logic.recurring")
local utils_mod = require("gtodo-md.utils")

-- テンプレートの {{名前}} に入れる値を、フロントマターの values: から決める。
-- 値の無い名前・タグにできない値があれば nil と理由。
local function placeholder_values(template_mod, def)
	local values = {}
	for _, name in ipairs(template_mod.list_placeholder_names(def.body)) do
		local raw = def.values[name]
		if raw == nil then
			return nil, string.format("no value for {{%s}} under 'values:'", name)
		end
		local value, err = template_mod.normalize_placeholder_value(name, raw)
		if not value then
			return nil, err
		end
		values[name] = value
	end
	return values
end

-- today ("YYYY-MM-DD") の分までの定期タスクを inbox.md へ足す。
-- 返り値: 足したタスクの数。inbox.md へ書けなければ error を投げる(呼び出し元のロックが捕まえて通知し、
-- 日次の整理を記録しないので、次の機会にやり直す)。
function M.create_due_tasks(today)
	-- ui/ は上位層だが、テンプレートの読み方(プレースホルダー・期日の解決)はそこにしか無いため遅延 require する。
	local template_mod = require("gtodo-md.ui.template")
	local state = require("gtodo-md.state")

	local names = template_mod.list_templates()
	-- 足す順序を、更新時刻ではなく名前で決める(gtodo (CLI) と同じ結果にするため)。
	table.sort(names)

	local defs = {}
	for _, name in ipairs(names) do
		local def = logic.read_definition(io_mod.read_lines(template_mod.path(name)))
		if def.recurring or def.error then
			defs[name] = def
		end
	end
	if next(defs) == nil then
		-- 定期タスクが無くなった(最後の 1 つをアーカイブした)ときも、残った記録は消す。
		-- 残すと、元に戻したときにアーカイブしていた間の回をさかのぼって作ってしまう。
		local recorded = state.read_recurring()
		if recorded and next(recorded) ~= nil then
			state.write_recurring({})
		end
		return 0
	end

	local recorded, broken = state.read_recurring()
	if not recorded then
		vim.notify(
			string.format(
				"[gtodo-md] recurring tasks were not created: .state.json is not a valid state file (%s)",
				broken
			),
			vim.log.levels.ERROR
		)
		return 0
	end

	local records = {}
	local new_lines = {}
	local created = {}
	local problems = {}
	for _, name in ipairs(names) do
		local def = defs[name]
		if def and def.error then
			table.insert(problems, string.format("%s: %s", name, def.error))
			-- 直るまで記録は動かさない(直った後に、逃した回の最後の 1 回分を作る)。
			records[name] = recorded[name]
		elseif def then
			local last = recorded[name]
			local occurrence = logic.latest_occurrence(def.rules, last, today)
			local ok = true
			if occurrence then
				local values, err = placeholder_values(template_mod, def)
				if not values then
					table.insert(problems, string.format("%s: %s", name, err))
					ok = false
				else
					local base_time = utils_mod.date_to_time(occurrence)
					local tasks = template_mod.extract_task_lines(def.body, base_time, values)
					if #tasks == 0 then
						table.insert(problems, string.format("%s: no task lines", name))
					else
						vim.list_extend(new_lines, tasks)
						table.insert(created, string.format("%s (%s)", name, occurrence))
					end
				end
			end
			if ok then
				-- 時計が戻った場合でも、記録は前へだけ進める。
				records[name] = (last and last > today) and last or today
			else
				records[name] = last
			end
		end
	end

	if #new_lines > 0 then
		local inbox_path = config.get("data_dir") .. "/inbox.md"
		local inbox_lines = io_mod.read_lines(inbox_path)
		vim.list_extend(inbox_lines, new_lines)
		io_mod.write_lines(inbox_path, inbox_lines)
	end

	-- 記録はアーカイブ・削除したテンプレートの分を含めずに置き換える(復元したときに、
	-- アーカイブしていた間の回をさかのぼって作らないように)。
	state.write_recurring(records)

	if #created > 0 then
		vim.notify(
			string.format(
				"[gtodo-md] Added %d recurring task(s) to inbox.md: %s",
				#new_lines,
				table.concat(created, ", ")
			),
			vim.log.levels.INFO
		)
	end
	if #problems > 0 then
		vim.notify(
			"[gtodo-md] Some recurring templates were skipped:\n" .. table.concat(problems, "\n"),
			vim.log.levels.WARN
		)
	end
	return #new_lines
end

return M
