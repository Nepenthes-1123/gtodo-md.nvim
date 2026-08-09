local M = {}
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")
local task_mod = require("gtodo-md.task")

-- テンプレートから挿入するタスクへ引き継いではいけないタグ。id/completed_at/done/
-- cancelled は ui/split.lua の NON_INHERITABLE_TAGS と同じ理由(id の複製が一意性を
-- 壊す、完了/キャンセルの記録を引き継ぐ意味が無い)による。split.lua のものは
-- 非公開のためここで別途定義する。
-- created は split.lua の子タスクでは意図的に継承されるが(CLAUDE.md参照)、
-- テンプレートは時間を跨いで繰り返し使うものなので、実タスク行のコピペ等で
-- created が紛れ込んでいた場合に古い日付を引きずるのは望ましくない。挿入された
-- タスクは通常の新規タスク追加と同じく created 未設定の状態にする。
local NON_INHERITABLE_TAGS = {
	id = true,
	completed_at = true,
	done = true,
	cancelled = true,
	created = true,
}

-- 既存テンプレート一覧の取得(最近更新された順)。ui/prompt.lua の get_projects と同じ方式。
function M.list_templates()
	local list = {}
	local data_dir = config.get("data_dir")
	local templates_dir = data_dir .. "/templates"
	if vim.fn.isdirectory(templates_dir) == 0 then
		return list
	end

	local files = vim.fn.globpath(templates_dir, "*.md", false, true)
	local temp = {}
	for _, file in ipairs(files) do
		local name = vim.fn.fnamemodify(file, ":t:r")
		local mtime = vim.fn.getftime(file)
		table.insert(temp, { name = name, mtime = mtime })
	end
	table.sort(temp, function(a, b)
		return a.mtime > b.mtime
	end)
	for _, item in ipairs(temp) do
		table.insert(list, item.name)
	end
	return list
end

-- テンプレート名は後で data_dir/templates/<name>.md へそのまま埋め込まれるため、
-- パストラバーサルを防ぐ目的で英数字・ハイフン・アンダースコアのみ許可する。
function M.validate_name(name)
	if type(name) ~= "string" or name == "" then
		return false
	end
	return name:match("^[%w%-_]+$") ~= nil
end

-- テンプレートファイルが無ければ、記法メモ付きで新規作成する(冪等)。
function M.ensure_template_file(name)
	if not M.validate_name(name) then
		vim.notify(string.format("[gtodo-md] invalid template name: %s", tostring(name)), vim.log.levels.ERROR)
		return false
	end

	local data_dir = config.get("data_dir")
	local templates_dir = data_dir .. "/templates"

	if vim.fn.isdirectory(templates_dir) == 0 then
		-- mkdir() は失敗時に 0 を返すほか、パス上に同名のファイルがある等では
		-- E739 を投げる。素通しにすると呼び出し元の処理がそこで止まる。
		local ok, created = pcall(vim.fn.mkdir, templates_dir, "p")
		if not ok or created == 0 then
			vim.notify(
				string.format("[gtodo-md] failed to create templates directory: %s", templates_dir),
				vim.log.levels.ERROR
			)
			return false
		end
	end

	local file = string.format("%s/%s.md", templates_dir, name)
	if vim.fn.filereadable(file) == 0 then
		local template = {
			"<!--",
			"記法メモ: - [ ] タスク内容 +project @context due:YYYY-MM-DD wait:理由",
			"due: は due:+3d / due:today / due:mon のような相対指定も可能(挿入時に選ぶ基準日から解決されます)",
			"優先度は内容の先頭に (A) のように付与 (例: - [ ] (A) 重要なタスク)",
			"このコメント行は挿入時に自動で無視されます",
			"-->",
			"",
		}
		local written, err = io_mod.atomic_write(file, table.concat(template, "\n") .. "\n")
		if not written then
			vim.notify(
				string.format("[gtodo-md] failed to create template file: %s (%s)", file, err),
				vim.log.levels.ERROR
			)
			return false
		end
	end

	return true
end

-- 行中の{{名前}}トークン(名前は[%w_]+、値の自由度とは別物の識別子)を出現順・重複無しで
-- 拾う純関数。タグ境界の判定は一切行わない(境界の判定は resolve_placeholders 側の責務)。
function M.list_placeholder_names(lines)
	local names = {}
	local seen = {}
	for _, line in ipairs(lines) do
		for name in line:gmatch("{{([%w_]+)}}") do
			if not seen[name] then
				seen[name] = true
				table.insert(names, name)
			end
		end
	end
	return names
end

-- {{project}}/{{context}}は予約トークンで、トークン自体がタグ全体(+value/@value)を表す。
-- 値が非空ならトークンをそのまま "+value"/"@value" へ置換する(周囲の空白には触れない)。
-- 値が空/未回答(valuesにキーが無い場合も同じ扱い)なら、タグごと消すと同時に周囲の
-- 空白も畳んで単一の半角スペースに揃える(二重空白/ゼロ空白を防ぐ)。
local function resolve_reserved_tag(line, name, prefix, value)
	if value and value ~= "" then
		return (line:gsub("{{" .. name .. "}}", prefix .. value))
	end
	return (line:gsub("%s*{{" .. name .. "}}%s*", " "))
end

-- {{名前}}トークンを解決する純関数。project/context は上記の予約タグ置換、それ以外は
-- 単純な文字列置換(本文への自由埋め込み用、タグ境界の判定は行わない)。
function M.resolve_placeholders(lines, values)
	values = values or {}
	local result = {}
	for _, line in ipairs(lines) do
		local resolved = line
		local seen = {}
		for name in line:gmatch("{{([%w_]+)}}") do
			if not seen[name] then
				seen[name] = true
				if name == "project" then
					resolved = resolve_reserved_tag(resolved, "project", "+", values.project)
				elseif name == "context" then
					resolved = resolve_reserved_tag(resolved, "context", "@", values.context)
				else
					resolved = resolved:gsub("{{" .. name .. "}}", values[name] or "")
				end
			end
		end
		table.insert(result, resolved)
	end
	return result
end

-- タスク行だけを抽出し、テンプレートから継承させないタグを外した上で再serializeする。
--
-- テンプレートは繰り返し使い回すものなので、due:の相対指定(due:+3d 等)を
-- 「挿入した瞬間の実日付」ではなく base_time(省略時は従来通り実際の今日) 基準で
-- 解決したい。しかし task_mod.parse は内部で utils.parse_due_date を base_time無しで
-- 呼ぶため、base_time を注入する余地が無い(task.lua の parse/serialize 契約は
-- テンプレート機能のためだけに変更できない)。そこでここで先に due: タグの位置を
-- task_mod.tag_ranges で特定し、生の相対指定を base_time 基準の絶対日付へ
-- 置換してから task_mod.parse へ渡す(以降は通常の絶対日付として素直にパースされる)。
--
-- placeholder_values が渡されれば、{{project}}等のプレースホルダーをdue:解決より前に
-- 解決する。tag_ranges は "{{...}}" を認識できない(TAG_PATTERNSの許容文字集合に
-- 中括弧が無い)ため、tag_ranges が動く時点で既に本物の +value/@value タグになって
-- いなければならない。
function M.extract_task_lines(lines, base_time, placeholder_values)
	local utils_mod = require("gtodo-md.utils")
	local resolved_lines = placeholder_values and M.resolve_placeholders(lines, placeholder_values) or lines
	local result = {}
	for _, line in ipairs(resolved_lines) do
		local resolved_line = line
		for _, r in ipairs(task_mod.tag_ranges(line)) do
			if r.key == "due" then
				-- tag_ranges の範囲は直前の空白を含む(highlight.lua の due日付ハイライトと同じ剥がし方)。
				local raw = line:sub(r.start_col + 1, r.end_col)
				local lead = raw:match("^%s*")
				local raw_value = raw:sub(#lead + 1):match("^due:(.*)$")
				local resolved = raw_value and utils_mod.parse_due_date(raw_value, base_time)
				if resolved and resolved ~= raw_value then
					local tag_start = r.start_col + #lead
					resolved_line = line:sub(1, tag_start) .. "due:" .. resolved .. line:sub(r.end_col + 1)
				end
				break
			end
		end

		local task = task_mod.parse(resolved_line)
		if task then
			for key in pairs(NON_INHERITABLE_TAGS) do
				task[key] = nil
			end
			table.insert(result, task_mod.serialize(task))
		end
	end
	return result
end

-- テンプレートのタスク行を inbox.md 末尾へ追記する。
function M.insert_template_tasks(name, base_time, placeholder_values)
	local data_dir = config.get("data_dir")
	local file = string.format("%s/templates/%s.md", data_dir, name)

	if vim.fn.filereadable(file) == 0 then
		vim.notify(string.format("[gtodo-md] template not found: %s", name), vim.log.levels.ERROR)
		return false
	end

	local lines = io_mod.read_lines(file)
	local tasks = M.extract_task_lines(lines, base_time, placeholder_values)
	if #tasks == 0 then
		vim.notify(string.format("[gtodo-md] no tasks found in template: %s", name), vim.log.levels.WARN)
		return false
	end

	local inbox_path = data_dir .. "/inbox.md"
	local inbox_lines = io_mod.read_lines(inbox_path)
	vim.list_extend(inbox_lines, tasks)
	io_mod.write_lines(inbox_path, inbox_lines)

	return true
end

-- テンプレートの新規作成/既存編集(フロートウィンドウでファイルを開く)。
-- vim.ui.select/vim.ui.input を使う対話的なオーケストレーションのため無テスト
-- (ui/prompt.lua と同じ既存の慣習に倣う)。
function M.edit_template()
	local sentinel = "New Template..."
	local options = { sentinel }
	vim.list_extend(options, M.list_templates())

	vim.ui.select(options, { prompt = "Select Template:" }, function(choice)
		if not choice then
			return
		end

		local data_dir = config.get("data_dir")

		if choice == sentinel then
			vim.ui.input({ prompt = "New Template Name: " }, function(input_name)
				if not input_name or vim.trim(input_name) == "" then
					return
				end
				local name = vim.trim(input_name)
				if not M.ensure_template_file(name) then
					return
				end
				local path = string.format("%s/templates/%s.md", data_dir, name)
				require("gtodo-md.ui.float").open_float(path, "Template: " .. name)
			end)
			return
		end

		local path = string.format("%s/templates/%s.md", data_dir, choice)
		require("gtodo-md.ui.float").open_float(path, "Template: " .. choice)
	end)
end

-- テンプレートを選んで inbox.md へタスクを挿入する。無テストの理由は edit_template と同じ。
function M.insert_template()
	local templates = M.list_templates()
	if #templates == 0 then
		vim.notify("[gtodo-md] No templates found. Create one first.", vim.log.levels.WARN)
		return
	end

	vim.ui.select(templates, { prompt = "Select Template:" }, function(choice)
		if not choice then
			return
		end

		local data_dir = config.get("data_dir")
		local path = string.format("%s/templates/%s.md", data_dir, choice)
		local lines = io_mod.read_lines(path)
		local placeholder_names = M.list_placeholder_names(lines)

		-- テンプレートは繰り返し使い回すため、due:の相対指定を「挿入した瞬間の実日付」
		-- ではなくユーザーが選んだ基準日から解決したい。この入力自体は常に実際の今日を
		-- 基準に解決する(基準日を選ぶための入力に、さらに別の基準日は無い)。
		local function prompt_base_date(values)
			vim.ui.input({ prompt = "Base Date (today, +3d, 2026-08-20, ...): ", default = "today" }, function(input)
				if not input then
					return
				end
				local trimmed = vim.trim(input)
				if trimmed == "" then
					trimmed = "today"
				end
				local utils_mod = require("gtodo-md.utils")
				local resolved_date = utils_mod.parse_due_date(trimmed)
				if not resolved_date then
					vim.notify("[gtodo-md] Invalid base date: " .. input, vim.log.levels.ERROR)
					return
				end
				local base_time = utils_mod.date_to_time(resolved_date)

				-- 失敗時(テンプレ不在/タスク0件)は insert_template_tasks 側で通知済みのため、
				-- ここでは成功時のみ通知する。
				if M.insert_template_tasks(choice, base_time, values) then
					vim.notify(
						string.format("[gtodo-md] Inserted tasks from template '%s' into inbox.md", choice),
						vim.log.levels.INFO
					)
				end
			end)
		end

		-- vim.ui.input は非同期のため、複数のプレースホルダーはループではなく再帰の
		-- チェインで1つずつ順番に尋ねる。全て尋ね終えたら base_time の入力へ進む。
		local function prompt_placeholders(names, index, values)
			local name = names[index]
			if not name then
				prompt_base_date(values)
				return
			end
			vim.ui.input({ prompt = "Value for {{" .. name .. "}} (blank to omit): " }, function(input)
				if input == nil then
					-- キャンセル(Esc)はbase_date入力時と同じく全体を中断する。
					return
				end
				local trimmed = vim.trim(input)
				if trimmed ~= "" then
					values[name] = trimmed
				end
				prompt_placeholders(names, index + 1, values)
			end)
		end

		if #placeholder_names > 0 then
			prompt_placeholders(placeholder_names, 1, {})
		else
			prompt_base_date({})
		end
	end)
end

return M
