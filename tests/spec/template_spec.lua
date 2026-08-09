-- タスクテンプレート機能(data_dir/templates/*.md)の仕様を固定する先行テスト。
--
-- 実装は lua/gtodo-md/ui/template.lua に以下の契約で追加する想定:
--   M.list_templates()          -> templates/*.md の名前一覧(拡張子無し、mtime降順)
--   M.validate_name(name)       -> [%w%-_]+ のみ許容する真偽値判定
--   M.ensure_template_file(name)-> 不正名ならエラー通知してfalse、未存在なら記法メモ付きで
--                                   新規作成してtrue、既存ならそのままtrue(上書きしない)
--   M.extract_task_lines(lines) -> task.parseできる行だけを、split.luaのNON_INHERITABLE_TAGS
--                                   (id/completed_at/done/cancelled)を除いて再serializeして返す
--   M.insert_template_tasks(name) -> templates/<name>.md を読み、extract_task_linesした結果を
--                                     inbox.md 末尾へ追記。テンプレ不在/タスク0件はfalseを返す
--
-- M.edit_template()/M.insert_template() は vim.ui.select/vim.ui.input を使う対話的な
-- オーケストレーション層で、このリポジトリの既存の慣習(ui/prompt.lua は無テスト)に
-- 倣いここでは対象外とする。

local template_mod = require("gtodo-md.ui.template")
local task_mod = require("gtodo-md.task")
local config = require("gtodo-md.config")
local io_mod = require("gtodo-md.io")

describe("ui.template", function()
	local data_dir
	local templates_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir, "p")
		templates_dir = data_dir .. "/templates"
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		vim.fn.delete(data_dir, "rf")
	end)

	describe("list_templates", function()
		it("templatesディレクトリが無い場合は空配列を返す", function()
			assert.are.same({}, template_mod.list_templates())
		end)

		it("*.md のみを対象に、mtime降順で名前(拡張子無し)を返す", function()
			-- vim.fn.setftime は存在しない(Vim/Neovimに無い関数)。mtimeを明示的に
			-- 前後させるには libuv の fs_utime を使う(lock.lua と同じ uv 取得パターン)。
			local uv = vim.uv or vim.loop
			vim.fn.mkdir(templates_dir, "p")
			vim.fn.writefile({ "- [ ] a" }, templates_dir .. "/old.md")
			vim.fn.writefile({ "not a template" }, templates_dir .. "/ignored.txt")
			local old_time = os.time() - 100
			uv.fs_utime(templates_dir .. "/old.md", old_time, old_time)
			vim.fn.writefile({ "- [ ] b" }, templates_dir .. "/new.md")
			local new_time = os.time()
			uv.fs_utime(templates_dir .. "/new.md", new_time, new_time)

			assert.are.same({ "new", "old" }, template_mod.list_templates())
		end)
	end)

	describe("validate_name", function()
		it("英数字・ハイフン・アンダースコアのみを許可する", function()
			assert.is_true(template_mod.validate_name("daily-setup"))
			assert.is_true(template_mod.validate_name("new_project_2"))
		end)

		it("パス区切りや相対パス指定を含む名前を拒否する", function()
			assert.is_false(template_mod.validate_name("../escape"))
			assert.is_false(template_mod.validate_name("foo/bar"))
			assert.is_false(template_mod.validate_name("with space"))
			assert.is_false(template_mod.validate_name(""))
			assert.is_false(template_mod.validate_name(nil))
		end)
	end)

	describe("ensure_template_file", function()
		it("不正な名前はファイル・ディレクトリを作らずfalseを返す", function()
			local ok = template_mod.ensure_template_file("../escape")
			assert.is_false(ok)
			assert.are.same(0, vim.fn.isdirectory(templates_dir))
		end)

		it("未存在なら templates/ を作成し、記法メモ付きの新規ファイルを作る", function()
			local ok = template_mod.ensure_template_file("daily-setup")
			assert.is_true(ok)

			local file = templates_dir .. "/daily-setup.md"
			assert.are.same(1, vim.fn.filereadable(file))

			local lines = vim.fn.readfile(file)
			assert.is_true(#lines > 0)
			for i, line in ipairs(lines) do
				assert.are.same(
					line,
					(line:gsub("%s+$", "")),
					"行 " .. i .. " に末尾の空白が残っている: " .. vim.inspect(line)
				)
			end

			-- 記法メモはタスク行として解釈されてはならない(挿入時に紛れ込むと事故になる)
			for _, line in ipairs(lines) do
				assert.is_nil(
					task_mod.parse(line),
					"記法メモがタスク行として解釈された: " .. vim.inspect(line)
				)
			end
		end)

		it("既存ファイルがある場合は内容を上書きしない(冪等)", function()
			vim.fn.mkdir(templates_dir, "p")
			vim.fn.writefile({ "- [ ] 既存のタスク" }, templates_dir .. "/daily-setup.md")

			local ok = template_mod.ensure_template_file("daily-setup")
			assert.is_true(ok)

			local lines = vim.fn.readfile(templates_dir .. "/daily-setup.md")
			assert.are.same({ "- [ ] 既存のタスク" }, lines)
		end)
	end)

	describe("extract_task_lines", function()
		it("task.parseできる行だけを元の順序で抽出する", function()
			local lines = {
				"<!-- 記法メモ -->",
				"",
				"- [ ] タスクA +project @context",
				"### 見出し行(タスクではない)",
				"- [ ] タスクB due:2026-01-01",
			}
			local result = template_mod.extract_task_lines(lines)
			assert.are.same(2, #result)

			local task_a = task_mod.parse(result[1])
			local task_b = task_mod.parse(result[2])
			assert.are.same("タスクA", task_a.content)
			assert.are.same("project", task_a.project)
			-- task.lua は context を "@" 付きで保持する(project とは非対称。
			-- tests/spec/task_roundtrip_spec.lua の既存契約と同じ)
			assert.are.same("@context", task_a.context)
			assert.are.same("タスクB", task_b.content)
			assert.are.same("2026-01-01", task_b.due)
		end)

		it(
			"id/completed_at/done/cancelled は継承させない(split.luaのNON_INHERITABLE_TAGSと同じ扱い)",
			function()
				local lines = {
					"- [x] 完了済みタスク id:abc123 completed_at:2026-01-01 done:2026-01-01",
				}
				local result = template_mod.extract_task_lines(lines)
				assert.are.same(1, #result)

				local task = task_mod.parse(result[1])
				assert.is_nil(task.completed_at)
				assert.is_nil(task.done)
				-- id は serialize 時に未発行なら自動発行されるため nil にはならないが、
				-- 元の "abc123" が引き継がれていないことだけを確認する
				assert.are_not.same("abc123", task.id)
			end
		)

		it("キャンセル済みタグも継承させない", function()
			local lines = { "- [ ] キャンセル済み cancelled:2026-01-01" }
			local result = template_mod.extract_task_lines(lines)
			local task = task_mod.parse(result[1])
			assert.is_nil(task.cancelled)
		end)

		it("空配列を渡された場合は空配列を返す", function()
			assert.are.same({}, template_mod.extract_task_lines({}))
		end)
	end)

	-- テンプレートは繰り返し使い回すものなので、due:+3d のような相対指定を
	-- 「挿入したその瞬間の実日付」基準で固定してしまうと、基準日をユーザーが
	-- 選べない。第2引数(base_time)でその挿入インスタンスの基準日を明示できる。
	describe(
		"extract_task_lines の base_time 引数(due:の相対指定をユーザー指定基準日で解決する)",
		function()
			it("due:の相対指定は実際の今日ではなくbase_time基準で解決される", function()
				local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
				local result = template_mod.extract_task_lines({ "- [ ] タスク due:+3d" }, base_time)
				local task = task_mod.parse(result[1])
				assert.are.same("2024-01-13", task.due)
			end)

			it("due:を挟む前後の +project/@context タグは書き換えられない", function()
				local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
				local result = template_mod.extract_task_lines({ "- [ ] タスク +proj due:+3d @ctx" }, base_time)
				local task = task_mod.parse(result[1])
				assert.are.same("proj", task.project)
				assert.are.same("@ctx", task.context)
				assert.are.same("2024-01-13", task.due)
			end)

			it("due:が絶対日付の場合はbase_timeに関わらず変化しない", function()
				local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
				local result = template_mod.extract_task_lines({ "- [ ] タスク due:2026-08-20" }, base_time)
				local task = task_mod.parse(result[1])
				assert.are.same("2026-08-20", task.due)
			end)

			it("due:を持たない行はbase_timeの影響を受けない", function()
				local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
				local result = template_mod.extract_task_lines({ "- [ ] due無しタスク" }, base_time)
				local task = task_mod.parse(result[1])
				assert.are.same("due無しタスク", task.content)
				assert.is_nil(task.due)
			end)

			it("base_timeを省略した場合は従来通り実際の今日を基準に解決される", function()
				local expected = os.date("%Y-%m-%d", os.time() + 3 * 24 * 3600)
				local result = template_mod.extract_task_lines({ "- [ ] タスク due:+3d" })
				local task = task_mod.parse(result[1])
				assert.are.same(expected, task.due)
			end)
		end
	)

	describe("insert_template_tasks", function()
		local inbox_path

		before_each(function()
			inbox_path = data_dir .. "/inbox.md"
			vim.fn.mkdir(templates_dir, "p")
		end)

		it(
			"存在しないテンプレートを指定した場合はfalseを返し、inbox.mdを変更しない",
			function()
				vim.fn.writefile({ "# Inbox", "" }, inbox_path)
				local ok = template_mod.insert_template_tasks("does-not-exist")
				assert.is_false(ok)
				assert.are.same({ "# Inbox", "" }, vim.fn.readfile(inbox_path))
			end
		)

		it("タスク行を含まないテンプレートはfalseを返し、inbox.mdを変更しない", function()
			vim.fn.writefile({ "# Inbox", "" }, inbox_path)
			vim.fn.writefile({ "<!-- メモのみ -->", "" }, templates_dir .. "/empty.md")

			local ok = template_mod.insert_template_tasks("empty")
			assert.is_false(ok)
			assert.are.same({ "# Inbox", "" }, vim.fn.readfile(inbox_path))
		end)

		it("テンプレートのタスク行を既存のinbox.md末尾へ順序を保って追記する", function()
			vim.fn.writefile({ "# Inbox", "", "- [ ] 既存タスク" }, inbox_path)
			vim.fn.writefile({
				"<!-- 記法メモ -->",
				"- [ ] 新規タスクA +new-project",
				"- [ ] 新規タスクB @context",
			}, templates_dir .. "/new-project.md")

			local ok = template_mod.insert_template_tasks("new-project")
			assert.is_true(ok)

			local lines = io_mod.read_lines(inbox_path)
			assert.are.same("# Inbox", lines[1])
			assert.are.same("- [ ] 既存タスク", lines[3])

			local task_a = task_mod.parse(lines[4])
			local task_b = task_mod.parse(lines[5])
			assert.are.same("新規タスクA", task_a.content)
			assert.are.same("new-project", task_a.project)
			assert.are.same("新規タスクB", task_b.content)
			assert.are.same("@context", task_b.context)
		end)

		it(
			"base_timeを渡すと、相対due指定がその基準日から解決されてinbox.mdへ追記される",
			function()
				vim.fn.writefile({ "# Inbox", "" }, inbox_path)
				vim.fn.writefile({
					"- [ ] 基準日+2日タスク due:+2d",
				}, templates_dir .. "/relative-due.md")

				local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
				local ok = template_mod.insert_template_tasks("relative-due", base_time)
				assert.is_true(ok)

				local lines = io_mod.read_lines(inbox_path)
				local task = task_mod.parse(lines[3])
				assert.are.same("2024-01-12", task.due)
			end
		)
	end)
end)
