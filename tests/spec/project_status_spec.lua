-- プロジェクトのアーカイブ/復元機能(未実装、先行テスト)。
--
-- projects/<tag>.md の frontmatter 内 status: フィールドを active <-> archived で
-- 切り替えることでアーカイブ/復元を実現する。ファイル自体は移動しない。
--
-- 実装は lua/gtodo-md/ui/project.lua に以下の契約で追加する想定:
--   M.set_project_status(project_tag, new_status)
--     -> (false, "notfound")        ファイルが無い
--     -> (false, "no_status_field") frontmatterにstatus:キーが無い
--     -> (true, "noop")             既にnew_statusと同じ値(ファイル変更なし)
--     -> (true, nil)                実際に書き換えた(status:行以外は一切変更しない)
--   M.list_active_project_tags()   -> status:がarchivedでない全プロジェクトタグをmtime降順で返す
--                                      (ブラックリスト方式: 独自ステータス値・status:欠落も含む)
--   M.list_archived_project_tags() -> status: archived のプロジェクトタグのみをmtime降順で返す
--   M.archive_project_file(tag)    -> set_project_status(tag, "archived") のラッパー
--   M.restore_project_file(tag)    -> set_project_status(tag, "active") のラッパー

local config = require("gtodo-md.config")
local project_mod = require("gtodo-md.ui.project")

describe("ui.project アーカイブ/復元", function()
	local data_dir
	local projects_dir

	-- create_project_file が生成する実際のフォーマット(project_template_spec.lua参照)に
	-- 揃えたfrontmatter付きmarkdownを組み立てるヘルパー。
	local function default_frontmatter(tag, status)
		return {
			"---",
			"title:",
			"tag: " .. tag,
			"created: 2026-01-01",
			"due:",
			"status: " .. status,
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
	end

	-- 手編集等でstatus:キー自体が欠落したケースの再現用。
	local function no_status_frontmatter(tag)
		return {
			"---",
			"title:",
			"tag: " .. tag,
			"created: 2026-01-01",
			"due:",
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
	end

	local function project_path(tag)
		return string.format("%s/%s.md", projects_dir, tag)
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		projects_dir = data_dir .. "/projects"
		vim.fn.mkdir(projects_dir, "p")
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		-- data_dir 配下を指す開いたままのバッファ(未保存バッファ回帰テスト用)を掃除する。
		-- no_op_write_spec.lua と同じパターン。
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				local bname = vim.api.nvim_buf_get_name(b)
				if bname ~= "" and bname:find(data_dir, 1, true) == 1 then
					pcall(vim.api.nvim_buf_delete, b, { force = true })
				end
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	describe("set_project_status", function()
		it('ファイルが無い場合は (false, "notfound") を返す', function()
			local ok, err = project_mod.set_project_status("no-such-project", "archived")
			assert.is_false(ok)
			assert.are.same("notfound", err)
		end)

		it('frontmatterにstatus:キーが無い場合は (false, "no_status_field") を返す', function()
			local tag = "no-status-key"
			vim.fn.writefile(no_status_frontmatter(tag), project_path(tag))

			local ok, err = project_mod.set_project_status(tag, "archived")
			assert.is_false(ok)
			assert.are.same("no_status_field", err)
		end)

		it('既に指定のstatusと同じ場合はファイルを変更せず (true, "noop") を返す', function()
			local tag = "already-active"
			local path = project_path(tag)
			vim.fn.writefile(default_frontmatter(tag, "active"), path)
			local before = vim.fn.readfile(path)

			local ok, err = project_mod.set_project_status(tag, "active")
			assert.is_true(ok)
			assert.are.same("noop", err)
			assert.are.same(before, vim.fn.readfile(path))
		end)

		it(
			"statusを書き換えた場合は (true, nil) を返し、status:行以外は一切変更されない",
			function()
				local tag = "rewrite-me"
				local path = project_path(tag)
				local lines = {
					"---",
					"title: My Project",
					"tag: " .. tag,
					"created: 2026-01-01",
					"due: 2026-12-31",
					"status: active",
					"members: [alice, bob]",
					"---",
					"",
					"## Overview",
					"",
					"Some overview text.",
					"",
					"## Notes",
					"",
					"Some notes text.",
					"",
					"## Reference",
					"",
				}
				vim.fn.writefile(lines, path)

				local ok, err = project_mod.set_project_status(tag, "archived")
				assert.is_true(ok)
				assert.is_nil(err)

				local expected = vim.deepcopy(lines)
				expected[6] = "status: archived"
				assert.are.same(expected, vim.fn.readfile(path))
			end
		)

		it("archived から active への書き換えも同様に動作する", function()
			local tag = "restore-me"
			local path = project_path(tag)
			local lines = default_frontmatter(tag, "archived")
			vim.fn.writefile(lines, path)

			local ok, err = project_mod.set_project_status(tag, "active")
			assert.is_true(ok)
			assert.is_nil(err)

			local expected = vim.deepcopy(lines)
			expected[6] = "status: active"
			assert.are.same(expected, vim.fn.readfile(path))
		end)

		it(
			"frontmatter終端(2つ目の---)より後の本文中に、たまたまstatus:で始まる行があっても書き換え対象にならない",
			function()
				local tag = "body-status-collision"
				local path = project_path(tag)
				local lines = {
					"---",
					"title:",
					"tag: " .. tag,
					"created: 2026-01-01",
					"due:",
					"status: active",
					"members: []",
					"---",
					"",
					"## Overview",
					"",
					"## Notes",
					"",
					"status: 会議待ち",
					"",
					"## Reference",
					"",
				}
				vim.fn.writefile(lines, path)

				local ok, err = project_mod.set_project_status(tag, "archived")
				assert.is_true(ok)
				assert.is_nil(err)

				local result = vim.fn.readfile(path)
				local expected = vim.deepcopy(lines)
				expected[6] = "status: archived"
				assert.are.same(expected, result)
				-- 本文中の "status: 会議待ち" 自体が消えていないことも明示的に確認する
				assert.are.same("status: 会議待ち", result[14])
			end
		)

		it(
			'対象ファイルに未保存(dirty)のバッファがある場合は (false, "buffer_dirty") を返し、ディスクを一切変更しない',
			function()
				local tag = "dirty-buf"
				local path = project_path(tag)
				vim.fn.writefile(default_frontmatter(tag, "active"), path)
				local before = vim.fn.readfile(path)

				local bufnr = vim.fn.bufadd(path)
				vim.fn.bufload(bufnr)
				vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "due: 2099-01-01(未保存の無関係な編集)" })
				assert.is_true(vim.bo[bufnr].modified, "前提: バッファが未保存(dirty)であること")

				local ok, err = project_mod.set_project_status(tag, "archived")

				assert.is_false(ok)
				assert.are.same("buffer_dirty", err)
				assert.are.same(
					before,
					vim.fn.readfile(path),
					"dirtyなバッファの未保存編集がディスクへ書き込まれている"
				)
				assert.is_true(vim.bo[bufnr].modified, "dirtyなバッファの未保存状態が失われた")
			end
		)
	end)

	describe("archive_project_file / restore_project_file", function()
		it('archive_project_file は set_project_status(tag, "archived") と同じ結果になる', function()
			local tag = "wrap-archive"
			vim.fn.writefile(default_frontmatter(tag, "active"), project_path(tag))

			local ok, err = project_mod.archive_project_file(tag)
			assert.is_true(ok)
			assert.is_nil(err)
			assert.are.same("status: archived", vim.fn.readfile(project_path(tag))[6])
		end)

		it('restore_project_file は set_project_status(tag, "active") と同じ結果になる', function()
			local tag = "wrap-restore"
			vim.fn.writefile(default_frontmatter(tag, "archived"), project_path(tag))

			local ok, err = project_mod.restore_project_file(tag)
			assert.is_true(ok)
			assert.is_nil(err)
			assert.are.same("status: active", vim.fn.readfile(project_path(tag))[6])
		end)

		it('archive_project_file はファイルが無ければ (false, "notfound") を返す', function()
			local ok, err = project_mod.archive_project_file("does-not-exist")
			assert.is_false(ok)
			assert.are.same("notfound", err)
		end)

		it('restore_project_file はファイルが無ければ (false, "notfound") を返す', function()
			local ok, err = project_mod.restore_project_file("does-not-exist")
			assert.is_false(ok)
			assert.are.same("notfound", err)
		end)

		it(
			'restore_project_file は既にactiveなら (true, "noop") を返しファイルを変更しない',
			function()
				local tag = "wrap-noop"
				local path = project_path(tag)
				vim.fn.writefile(default_frontmatter(tag, "active"), path)
				local before = vim.fn.readfile(path)

				local ok, err = project_mod.restore_project_file(tag)
				assert.is_true(ok)
				assert.are.same("noop", err)
				assert.are.same(before, vim.fn.readfile(path))
			end
		)

		it(
			'archive_project_file は既にarchivedなら (true, "noop") を返しファイルを変更しない',
			function()
				local tag = "wrap-noop-2"
				local path = project_path(tag)
				vim.fn.writefile(default_frontmatter(tag, "archived"), path)
				local before = vim.fn.readfile(path)

				local ok, err = project_mod.archive_project_file(tag)
				assert.is_true(ok)
				assert.are.same("noop", err)
				assert.are.same(before, vim.fn.readfile(path))
			end
		)
	end)

	describe("list_active_project_tags / list_archived_project_tags", function()
		it(
			"list_active_project_tags はarchived以外の全プロジェクト(独自ステータス値・status:欠落も含む)をmtime降順で返す(ブラックリスト方式の回帰)",
			function()
				local uv = vim.uv or vim.loop

				vim.fn.writefile(default_frontmatter("proj-active", "active"), project_path("proj-active"))
				vim.fn.writefile(default_frontmatter("proj-onhold", "on-hold"), project_path("proj-onhold"))
				vim.fn.writefile(no_status_frontmatter("proj-missing"), project_path("proj-missing"))
				vim.fn.writefile(default_frontmatter("proj-archived", "archived"), project_path("proj-archived"))

				local base = os.time()
				uv.fs_utime(project_path("proj-active"), base - 300, base - 300)
				uv.fs_utime(project_path("proj-onhold"), base - 200, base - 200)
				uv.fs_utime(project_path("proj-missing"), base - 100, base - 100)
				uv.fs_utime(project_path("proj-archived"), base, base)

				local tags = project_mod.list_active_project_tags()
				assert.are.same({ "proj-missing", "proj-onhold", "proj-active" }, tags)
			end
		)

		it(
			"list_archived_project_tags は status: archived のプロジェクトのみをmtime降順で返す",
			function()
				local uv = vim.uv or vim.loop

				vim.fn.writefile(default_frontmatter("active-only", "active"), project_path("active-only"))
				vim.fn.writefile(default_frontmatter("archived-old", "archived"), project_path("archived-old"))
				vim.fn.writefile(default_frontmatter("archived-new", "archived"), project_path("archived-new"))

				local base = os.time()
				uv.fs_utime(project_path("active-only"), base - 300, base - 300)
				uv.fs_utime(project_path("archived-old"), base - 200, base - 200)
				uv.fs_utime(project_path("archived-new"), base - 100, base - 100)

				local tags = project_mod.list_archived_project_tags()
				assert.are.same({ "archived-new", "archived-old" }, tags)
			end
		)

		it("projectsディレクトリが空の場合は両方とも空配列を返す", function()
			assert.are.same({}, project_mod.list_active_project_tags())
			assert.are.same({}, project_mod.list_archived_project_tags())
		end)
	end)

	describe("キャッシュの正しさ(回帰)", function()
		it(
			"list_active_project_tags を呼んだ後にarchiveすると、次回の呼び出しでは一覧から消える",
			function()
				vim.fn.writefile(default_frontmatter("proj-a", "active"), project_path("proj-a"))
				vim.fn.writefile(default_frontmatter("proj-b", "active"), project_path("proj-b"))

				-- 1回目の呼び出しでキャッシュがあれば構築されるはず
				local before = project_mod.list_active_project_tags()
				assert.is_true(vim.tbl_contains(before, "proj-a"))
				assert.is_true(vim.tbl_contains(before, "proj-b"))

				local ok = project_mod.archive_project_file("proj-a")
				assert.is_true(ok)

				local after = project_mod.list_active_project_tags()
				assert.is_false(
					vim.tbl_contains(after, "proj-a"),
					"archive後もキャッシュ経由の古い一覧が返っている"
				)
				assert.is_true(vim.tbl_contains(after, "proj-b"))
			end
		)

		it(
			"list_archived_project_tags を呼んだ後にrestoreすると、次回の呼び出しでは一覧から消える",
			function()
				vim.fn.writefile(default_frontmatter("proj-c", "archived"), project_path("proj-c"))

				local before = project_mod.list_archived_project_tags()
				assert.is_true(vim.tbl_contains(before, "proj-c"))

				local ok = project_mod.restore_project_file("proj-c")
				assert.is_true(ok)

				local after = project_mod.list_archived_project_tags()
				assert.is_false(
					vim.tbl_contains(after, "proj-c"),
					"restore後もキャッシュ経由の古い一覧が返っている"
				)
			end
		)
	end)

	describe("未保存バッファの反映(回帰)", function()
		it(
			"ディスク未保存でもバッファ側のstatus: archivedを優先して一覧から除外する(io.read_lines のバッファ優先読み込みとの整合)",
			function()
				local tag = "proj-buf"
				local path = project_path(tag)
				vim.fn.writefile(default_frontmatter(tag, "active"), path)

				local bufnr = vim.fn.bufadd(path)
				vim.fn.bufload(bufnr)

				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				local status_idx
				for i, line in ipairs(lines) do
					if line:match("^status:") then
						status_idx = i
						break
					end
				end
				assert.is_not_nil(status_idx, "フロントマターにstatus:行が見つからない(前提条件)")

				vim.api.nvim_buf_set_lines(bufnr, status_idx - 1, status_idx, false, { "status: archived" })

				-- 前提条件: バッファは未保存(dirty)で、ディスクはまだactiveのまま
				assert.is_true(
					vim.bo[bufnr].modified,
					"バッファが未保存として扱われていない(前提条件)"
				)
				assert.are.same(
					"status: active",
					vim.fn.readfile(path)[6],
					"ディスクが既に書き換わっている(前提条件)"
				)

				local tags = project_mod.list_active_project_tags()
				assert.is_false(
					vim.tbl_contains(tags, tag),
					"未保存バッファの内容が一覧に反映されていない"
				)
			end
		)

		it(
			"バッファ側でarchivedからactiveへ戻した場合はlist_archived_project_tagsから除外される",
			function()
				local tag = "proj-buf-restore"
				local path = project_path(tag)
				vim.fn.writefile(default_frontmatter(tag, "archived"), path)

				local bufnr = vim.fn.bufadd(path)
				vim.fn.bufload(bufnr)

				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				local status_idx
				for i, line in ipairs(lines) do
					if line:match("^status:") then
						status_idx = i
						break
					end
				end
				assert.is_not_nil(status_idx, "フロントマターにstatus:行が見つからない(前提条件)")

				vim.api.nvim_buf_set_lines(bufnr, status_idx - 1, status_idx, false, { "status: active" })
				assert.is_true(
					vim.bo[bufnr].modified,
					"バッファが未保存として扱われていない(前提条件)"
				)

				local archived_tags = project_mod.list_archived_project_tags()
				assert.is_false(vim.tbl_contains(archived_tags, tag))

				local active_tags = project_mod.list_active_project_tags()
				assert.is_true(vim.tbl_contains(active_tags, tag))
			end
		)
	end)
end)
