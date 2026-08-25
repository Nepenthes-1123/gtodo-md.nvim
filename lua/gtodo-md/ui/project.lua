local M = {}
local config = require("gtodo-md.config")
local float_ui = require("gtodo-md.ui.float")
local io_mod = require("gtodo-md.io")
local task_mod = require("gtodo-md.task")
local utils_mod = require("gtodo-md.utils")
local validate_mod = require("gtodo-md.validate")
local uv = vim.uv or vim.loop

-- done.md のカウントキャッシュ
local done_cache = {
	mtime = 0,
	counts = {},
}

-- キャッシュ機構による高速化 (active tasks)
M._active_cache = { inbox_mtime = -1, todo_mtime = -1, projects = {} }

-- done.md から高速にプロジェクトごとの完了件数を取得するヘルパー
local function get_done_project_counts(done_path)
	if vim.fn.filereadable(done_path) == 0 then
		return {}
	end
	local current_mtime = vim.fn.getftime(done_path)
	if current_mtime == done_cache.mtime then
		return done_cache.counts
	end

	local counts = {}
	local f = io.open(done_path, "r")
	if f then
		local content = f:read("*all")
		f:close()

		-- 高速テキスト走査で完了タスクとプロジェクトタグをカウント
		for line in content:gmatch("[^\r\n]+") do
			if task_mod.is_done_line(line) then
				local task = task_mod.parse(line)
				local tag = task and task.project
				if tag then
					counts[tag] = (counts[tag] or 0) + 1
				end
			end
		end
	end

	done_cache.mtime = current_mtime
	done_cache.counts = counts
	return counts
end

-- プロジェクトタグに対応する projects/*.md を、無ければテンプレート付きで作成する。
-- ジャンプ(jump_to_project)・分割時のプロジェクト昇格(ui/split.lua)・
-- 新規タスク入力時のプロジェクト作成(ui/prompt.lua)の3箇所から呼ばれる。
function M.create_project_file(project_tag)
	local data_dir = config.get("data_dir")
	local projects_dir = data_dir .. "/projects"

	-- mkdir() は失敗時に 0 を返すほか、パス上に同名のファイルがある等では
	-- E739 を投げる。素通しにすると呼び出し元の処理がそこで止まる。
	if not utils_mod.ensure_dir(projects_dir) then
		vim.notify(
			string.format("[gtodo-md] failed to create projects directory: %s", projects_dir),
			vim.log.levels.ERROR
		)
		return false
	end

	local proj_file = string.format("%s/%s.md", projects_dir, project_tag)
	if vim.fn.filereadable(proj_file) == 0 then
		local today = os.date("%Y-%m-%d")
		local template = {
			"---",
			"title:",
			"tag: " .. project_tag,
			"created: " .. today,
			"due:",
			"status: active",
			"members: []",
			"---",
			"",
			"## Overview",
			"",
			"## Notes",
			"",
			"## Reference",
			"",
		}

		local written, err = io_mod.atomic_write(proj_file, table.concat(template, "\n") .. "\n")
		if not written then
			vim.notify(string.format("Failed to create project file: %s (%s)", proj_file, err), vim.log.levels.ERROR)
			return false
		end
		vim.notify("Created new project file: " .. project_tag, vim.log.levels.INFO)
		return true
	end
	return true
end

-- プロジェクトファイルへのジャンプ
function M.jump_to_project()
	local current_line = vim.api.nvim_get_current_line()
	local task = task_mod.parse(current_line)
	local project_tag = task and task.project

	if not project_tag then
		return
	end

	local data_dir = config.get("data_dir")
	local proj_file = string.format("%s/projects/%s.md", data_dir, project_tag)

	if vim.fn.filereadable(proj_file) == 0 then
		local ok = M.create_project_file(project_tag)
		if not ok then
			return
		end
	end

	float_ui.open_float(proj_file, "Project: " .. project_tag)
end

function M.render_project_tasks(bufnr)
	if not bufnr or bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end

	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local filedir = vim.fn.fnamemodify(bufname, ":h:t")
	local filename = vim.fn.fnamemodify(bufname, ":t:r")

	-- projects ディレクトリ配下の markdown ファイルのみ対象
	if filedir ~= "projects" or vim.fn.fnamemodify(bufname, ":e") ~= "md" then
		return
	end

	local data_dir = config.get("data_dir")
	local inbox_path = data_dir .. "/inbox.md"
	local todo_path = data_dir .. "/todo.md"
	local project_tag = filename

	local active_tasks = {}
	local completed_count = 0

	-- done.md から過去の完了件数を取得 (高速キャッシュ経由)
	local done_path = data_dir .. "/done.md"
	local done_counts = get_done_project_counts(done_path)
	completed_count = completed_count + (done_counts[project_tag] or 0)

	local inbox_mtime = vim.fn.getftime(inbox_path)
	local todo_mtime = vim.fn.getftime(todo_path)

	local is_modified = false
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
			local bname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
			if bname == "inbox.md" or bname == "todo.md" then
				is_modified = true
			end
		end
	end

	local projects = M._active_cache.projects

	if is_modified or M._active_cache.inbox_mtime ~= inbox_mtime or M._active_cache.todo_mtime ~= todo_mtime then
		projects = {}

		local function parse_and_accumulate(filepath)
			if vim.fn.filereadable(filepath) == 1 then
				local data = io_mod.read_todo_file(filepath)
				for _, section_items in pairs(data.sections) do
					for _, item in ipairs(section_items) do
						if item.type == "task" and item.task.project then
							local p = item.task.project
							if not projects[p] then
								projects[p] = { active = {}, completed = 0 }
							end
							if item.task.status == "x" then
								projects[p].completed = projects[p].completed + 1
							else
								table.insert(projects[p].active, item.task)
							end
						end
					end
				end
			end
		end

		parse_and_accumulate(inbox_path)
		parse_and_accumulate(todo_path)

		if not is_modified then
			M._active_cache.inbox_mtime = inbox_mtime
			M._active_cache.todo_mtime = todo_mtime
			M._active_cache.projects = projects
		end
	end

	local proj_data = projects[project_tag]
	if proj_data then
		active_tasks = proj_data.active
		completed_count = completed_count + proj_data.completed
	end

	-- 仮想テキストの描画処理
	local ns_id = vim.api.nvim_create_namespace("gtodo_project_tasks")
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	local total_count = #active_tasks + completed_count
	if total_count == 0 then
		return
	end

	-- 仮想行の組み立て
	local virt_lines = {
		{ { "", "" } },
		{ { "----------------------------------------", "Comment" } },
	}

	local show_progress = config.get("enable_project_progress")
	if show_progress == nil then
		show_progress = true
	end

	if show_progress then
		-- 進捗率と進捗バーの計算
		local progress_percent = 0
		if total_count > 0 then
			progress_percent = math.floor((completed_count / total_count) * 100)
		end

		local bar_width = 10
		local filled = math.floor((progress_percent / 100) * bar_width)
		local empty = bar_width - filled
		local bar_str = string.format(
			"[%s%s] %d%% (%d/%d done)",
			string.rep("█", filled),
			string.rep("░", empty),
			progress_percent,
			completed_count,
			total_count
		)
		table.insert(virt_lines, { { "[gtodo-md] プロジェクト進捗: " .. bar_str, "DiagnosticOk" } })
	end

	if #active_tasks > 0 then
		table.insert(virt_lines, { { "[gtodo-md] 進行中のタスク (+" .. project_tag .. "):", "Comment" } })
		for _, task in ipairs(active_tasks) do
			local line_parts = {}
			table.insert(line_parts, { "  - [ ] ", "Comment" })
			table.insert(line_parts, { task.content, "Comment" })

			if task.context then
				table.insert(line_parts, { " @" .. task.context, "Comment" })
			end

			if task.due then
				table.insert(line_parts, { " due:" .. task.due, "Comment" })
			end

			table.insert(virt_lines, line_parts)
		end
	else
		table.insert(virt_lines, { { "[gtodo-md] すべてのタスクが完了しました！", "DiagnosticOk" } })
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_count - 1, 0, {
		virt_lines = virt_lines,
		virt_lines_above = false,
	})
end

-- inbox.md / todo.md への書き込み後、開いているプロジェクトバッファの進捗仮想テキストを更新する。
-- io.write_lines が :write を使わなくなったため、旧実装が依存していた
-- BufWritePost 経由の自動更新が効かなくなった分をここで肩代わりする。
-- 対象ファイルの判定は「どのファイルがプロジェクト進捗に影響するか」という
-- 上位層の関心事のため、io 側ではなくこちらに置く。
io_mod.add_write_observer(function(path)
	local filename = vim.fn.fnamemodify(path, ":t")
	if filename ~= "inbox.md" and filename ~= "todo.md" then
		return
	end
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			M.render_project_tasks(b)
		end
	end
end)

-- === プロジェクトのアーカイブ/復元 ===
--
-- projects/<tag>.md の frontmatter 内 status: フィールドを active <-> archived で
-- 切り替えることでアーカイブ/復元を実現する。ファイル自体は移動しない。

local function project_file_path(project_tag)
	local data_dir = config.get("data_dir")
	return string.format("%s/projects/%s.md", data_dir, project_tag)
end

-- frontmatter境界(validate.frontmatter_end_index)内に限定してstatus:行を探す。
-- 本文中に偶然 "status:" で始まる行があっても、境界の外なので無視される。
-- 戻り値: status_idx(1-indexed の行番号, 無ければnil), status_value(見つかった値)
local function find_status_line(lines)
	local end_idx = validate_mod.frontmatter_end_index(lines)
	if not end_idx then
		return nil, nil
	end
	for i = 2, end_idx - 1 do
		local value = lines[i]:match("^status:%s*(.*)$")
		if value then
			return i, value
		end
	end
	return nil, nil
end

-- 一覧関数(list_active_project_tags/list_archived_project_tags)向けの
-- status: 値キャッシュ。パスごとに { stat_key, status } を保持する。
-- stat_key は mtime(sec+nsec)+size から組み立てる — set_project_status による
-- 書き換えは値の文字数が変わる("active"<->"archived")ため、必ず size が動き
-- キャッシュは自然に無効化される(明示的なinvalidateは不要)。
M._status_cache = {}

-- 指定パスのプロジェクトファイルの status: 値を返す(無ければnil)。
-- ロード済みバッファが未保存(dirty)の場合は、そのバッファの内容を優先して
-- 毎回読み直し、キャッシュへは保存しない(io.read_lines のバッファ優先読み込みとの整合)。
local function project_status(path)
	local buf = io_mod.find_buf(path)
	if buf and vim.bo[buf].modified then
		local _, status = find_status_line(io_mod.read_lines(path))
		return status
	end

	local st = uv.fs_stat(path)
	local stat_key = st and string.format("%d:%d:%d", st.mtime.sec, st.mtime.nsec or 0, st.size) or nil

	local cached = M._status_cache[path]
	if cached and stat_key and cached.stat_key == stat_key then
		return cached.status
	end

	local _, status = find_status_line(io_mod.read_lines(path))
	if stat_key then
		M._status_cache[path] = { stat_key = stat_key, status = status }
	end
	return status
end

-- projects/ 配下の *.md を、predicate(status) が真を返すものだけmtime降順のタグ名で返す。
-- ソートは既存の io_mod.list_md_basenames_by_mtime と同じく vim.fn.getftime を使う。
local function collect_project_tags(predicate)
	local data_dir = config.get("data_dir")
	local projects_dir = data_dir .. "/projects"
	if vim.fn.isdirectory(projects_dir) == 0 then
		return {}
	end

	local files = vim.fn.globpath(projects_dir, "*.md", false, true)
	local temp = {}
	for _, file in ipairs(files) do
		local name = vim.fn.fnamemodify(file, ":t:r")
		-- globpath はOS標準のパス区切り(Windowsではバックスラッシュ)で返すことがあるが、
		-- バッファはこのファイル内の他の関数群と同じく "/" 区切りで開かれる
		-- (io.find_buf は区切り文字の正規化までは行わないため、ここで揃えないと
		-- 未保存バッファの検出が一致しない)。project_file_path で組み立て直した
		-- 正準パスを使う。
		local canonical_path = project_file_path(name)
		if predicate(project_status(canonical_path)) then
			table.insert(temp, { name = name, mtime = vim.fn.getftime(file) })
		end
	end
	table.sort(temp, function(a, b)
		return a.mtime > b.mtime
	end)

	local names = {}
	for _, item in ipairs(temp) do
		table.insert(names, item.name)
	end
	return names
end

-- status: がarchivedでない全プロジェクトタグをmtime降順で返す(ブラックリスト方式:
-- 独自ステータス値・status:欠落も含む)。
function M.list_active_project_tags()
	return collect_project_tags(function(status)
		return status ~= "archived"
	end)
end

-- status: archived のプロジェクトタグのみをmtime降順で返す。
function M.list_archived_project_tags()
	return collect_project_tags(function(status)
		return status == "archived"
	end)
end

-- projects/<project_tag>.md の frontmatter 内 status: を new_status へ書き換える。
--   -> (false, "notfound")        ファイルが無い
--   -> (false, "buffer_dirty")    対象ファイルに未保存(dirty)のバッファが開かれている
--   -> (false, "no_status_field") frontmatterにstatus:キーが無い
--   -> (true, "noop")             既にnew_statusと同じ値(ファイル変更なし)
--   -> (true, nil)                実際に書き換えた(status:行以外は一切変更しない)
--
-- read_lines はバッファ優先で読むため、対象ファイルが未保存の無関係な編集
-- (due:の削除、created:の書き換え等)を抱えたまま開かれていると、status:行の
-- 書き換えにその編集ごと巻き込んでディスクへ確定してしまう。write_lines は
-- :write を経由しないため autocmds.lua の BufWritePre フロントマター検証も
-- 通らない。ui/template.lua の release_template_buffer(dirtyならアーカイブを
-- 拒否する)と同じ方針で、dirtyな場合は書き込み自体を拒否する。
function M.set_project_status(project_tag, new_status)
	local path = project_file_path(project_tag)
	if vim.fn.filereadable(path) == 0 then
		return false, "notfound"
	end

	local buf = io_mod.find_buf(path)
	if buf and vim.bo[buf].modified then
		return false, "buffer_dirty"
	end

	local lines = io_mod.read_lines(path)
	local status_idx, current_status = find_status_line(lines)
	if not status_idx then
		return false, "no_status_field"
	end

	if current_status == new_status then
		return true, "noop"
	end

	lines[status_idx] = "status: " .. new_status
	local ok, err = pcall(io_mod.write_lines, path, lines)
	if not ok then
		return false, err
	end
	return true, nil
end

-- set_project_status(tag, "archived") のラッパー。
function M.archive_project_file(project_tag)
	return M.set_project_status(project_tag, "archived")
end

-- set_project_status(tag, "active") のラッパー。
function M.restore_project_file(project_tag)
	return M.set_project_status(project_tag, "active")
end

local function notify_status_failure(action, project_tag, reason)
	if reason == "notfound" then
		vim.notify(string.format("[gtodo-md] project not found: %s", project_tag), vim.log.levels.ERROR)
	elseif reason == "no_status_field" then
		vim.notify(
			string.format("[gtodo-md] project '%s' frontmatter has no status: field", project_tag),
			vim.log.levels.ERROR
		)
	elseif reason == "buffer_dirty" then
		vim.notify(
			string.format("[gtodo-md] project '%s' has unsaved changes; save or discard them first", project_tag),
			vim.log.levels.ERROR
		)
	else
		vim.notify(
			string.format("[gtodo-md] failed to %s project '%s': %s", action, project_tag, tostring(reason)),
			vim.log.levels.ERROR
		)
	end
end

-- プロジェクトを選んでアーカイブする。vim.ui.select を使う対話的オーケストレーションのため
-- 無テスト(edit_template/insert_templateと同じ既存の慣習)。
function M.archive_project()
	local tags = M.list_active_project_tags()
	if #tags == 0 then
		vim.notify("[gtodo-md] No projects found.", vim.log.levels.WARN)
		return
	end

	vim.ui.select(tags, { prompt = "Archive Project:" }, function(choice)
		if not choice then
			return
		end
		local ok, reason = M.archive_project_file(choice)
		if not ok then
			notify_status_failure("archive", choice, reason)
			return
		end
		if reason == "noop" then
			vim.notify(string.format("[gtodo-md] project '%s' is already archived", choice), vim.log.levels.WARN)
			return
		end
		vim.notify(string.format("[gtodo-md] Archived project '%s'", choice), vim.log.levels.INFO)
	end)
end

-- アーカイブ済みプロジェクトを選んで復元する。無テストの理由はarchive_projectと同じ。
function M.restore_project()
	local tags = M.list_archived_project_tags()
	if #tags == 0 then
		vim.notify("[gtodo-md] No archived projects found.", vim.log.levels.WARN)
		return
	end

	vim.ui.select(tags, { prompt = "Restore Project:" }, function(choice)
		if not choice then
			return
		end
		local ok, reason = M.restore_project_file(choice)
		if not ok then
			notify_status_failure("restore", choice, reason)
			return
		end
		if reason == "noop" then
			vim.notify(string.format("[gtodo-md] project '%s' is already active", choice), vim.log.levels.WARN)
			return
		end
		vim.notify(string.format("[gtodo-md] Restored project '%s'", choice), vim.log.levels.INFO)
	end)
end

return M
