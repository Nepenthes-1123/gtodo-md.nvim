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

		-- created: は split.lua の子タスクでは継承される(意図的、CLAUDE.md参照)が、
		-- テンプレートは時間を跨いで繰り返し使うものなので、実タスク行のコピペ等で
		-- created: が紛れ込んでいた場合に古い日付を引きずるのは望ましくない。
		-- 挿入されたタスクは通常の新規タスク追加と同じく created: 未設定の状態にする。
		it(
			"created: も継承させない(実タスク行のコピペで古い日付を引きずらないため)",
			function()
				local lines = { "- [ ] 古い日付混入タスク created:2020-01-01" }
				local result = template_mod.extract_task_lines(lines)
				local task = task_mod.parse(result[1])
				assert.is_nil(task.created)
			end
		)

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

	-- {{project}}/{{context}}のような予約プレースホルダートークン。
	-- 同じテンプレートを複数プロジェクトで使い回したいケースに対応する。
	-- {{project}}/{{context}} はタグ全体を表す予約語(トークン自体が +/@ を意味するので
	-- テンプレートには +{{project}} ではなく {{project}} 単体を書く)。それ以外の名前は
	-- 単純な文字列置換(本文への自由埋め込み用、タグ境界の判定は行わない)。
	describe("list_placeholder_names", function()
		it("行中の{{名前}}を出現順・重複無しで返す", function()
			local names = template_mod.list_placeholder_names({
				"- [ ] {{project}}のタスク {{context}}",
				"- [ ] 別行 {{project}} {{client}}",
			})
			assert.are.same({ "project", "context", "client" }, names)
		end)

		it("プレースホルダーが無ければ空配列を返す", function()
			assert.are.same({}, template_mod.list_placeholder_names({ "- [ ] 通常タスク" }))
		end)
	end)

	-- バグ4: list_placeholder_names がテンプレートの説明コメント(<!-- ... -->)内の
	-- 文字列まで{{name}}として拾ってしまう不具合。ensure_template_file が生成する
	-- 雛形の説明文自体に "{{project}}/{{context}}" という文字列が含まれるため、
	-- タスク行として解釈できる行(task_mod.parse(line) ~= nil)だけを対象にすべき。
	describe("list_placeholder_names はタスク行以外の{{name}}を無視する(バグ4)", function()
		it("コメント行(task.parseできない行)に含まれる{{name}}は対象外", function()
			local names = template_mod.list_placeholder_names({
				"<!-- {{project}}/{{context}} と書くと挿入時に値を尋ねます -->",
				"- [ ] 通常タスク +proj",
			})
			assert.are.same({}, names)
		end)

		it("見出し行に含まれる{{name}}も対象外", function()
			local names = template_mod.list_placeholder_names({
				"### {{heading}} セクション",
				"- [ ] タスク {{client}}",
			})
			assert.are.same({ "client" }, names)
		end)

		it("タスク行の{{name}}のみを出現順・重複無しで拾う(コメント行と混在)", function()
			local names = template_mod.list_placeholder_names({
				"<!-- {{project}}/{{context}} と書くと挿入時に値を尋ねます -->",
				"- [ ] {{client}}のタスク",
			})
			assert.are.same({ "client" }, names)
		end)
	end)

	describe("resolve_placeholders", function()
		it("{{project}}に値があれば+付きタグへ置換する", function()
			local result = template_mod.resolve_placeholders(
				{ "- [ ] 提案書作成 {{project}} @30" },
				{ project = "acme" }
			)
			local task = task_mod.parse(result[1])
			assert.are.same("提案書作成", task.content)
			assert.are.same("acme", task.project)
			assert.are.same("@30", task.context)
		end)

		it("{{context}}に値があれば@付きタグへ置換する", function()
			local result = template_mod.resolve_placeholders({ "- [ ] タスク {{context}}" }, { context = "office" })
			local task = task_mod.parse(result[1])
			assert.are.same("@office", task.context)
		end)

		it("{{project}}が空文字なら周囲の空白を含めてタグごと綺麗に消える", function()
			local result = template_mod.resolve_placeholders(
				{ "- [ ] 提案書作成 {{project}} @30" },
				{ project = "" }
			)
			assert.are.same("- [ ] 提案書作成 @30", result[1])
			local task = task_mod.parse(result[1])
			assert.is_nil(task.project)
			assert.are.same("提案書作成", task.content)
		end)

		it("valuesにキーが無い(未回答)場合も空文字と同じ扱いで消える", function()
			local result = template_mod.resolve_placeholders({ "- [ ] 提案書作成 {{project}} @30" }, {})
			assert.are.same("- [ ] 提案書作成 @30", result[1])
		end)

		it(
			"project/context以外の名前は単純な文字列置換になる(本文への自由埋め込み)",
			function()
				local result = template_mod.resolve_placeholders(
					{ "- [ ] {{client}}への提案書作成" },
					{ client = "ACME" }
				)
				local task = task_mod.parse(result[1])
				assert.are.same("ACMEへの提案書作成", task.content)
			end
		)

		it("プレースホルダーを含まない行はそのまま返す", function()
			local result = template_mod.resolve_placeholders({ "- [ ] 通常タスク +proj" }, { project = "other" })
			assert.are.same("- [ ] 通常タスク +proj", result[1])
		end)
	end)

	-- バグ1: {{name}}プレースホルダーの値に"%"が含まれると、内部でgsubの置換引数に
	-- ユーザー入力をそのまま渡している場合クラッシュ/文字化けする(Luaのgsub置換文字列は
	-- %1-%9をキャプチャ参照として、%%のみを単一の%として解釈し、それ以外の%Xはエラーになる)。
	-- 修正後は値に含まれる%が常にそのまま1文字として結果に現れ、エラーも起きてはいけない。
	describe("resolve_placeholders の値に%が含まれる場合(バグ1)", function()
		it(
			"予約プレースホルダー{{project}}の値に%が含まれてもエラーにならず、そのまま1文字として現れる",
			function()
				local result
				assert.has_no.errors(function()
					result = template_mod.resolve_placeholders(
						{ "- [ ] タスク {{project}}" },
						{ project = "50%off" }
					)
				end)
				assert.is_not_nil(result[1]:find("+50%off", 1, true), vim.inspect(result[1]))
			end
		)

		it(
			"予約プレースホルダー{{context}}の値に%が含まれてもエラーにならず、そのまま1文字として現れる",
			function()
				local result
				assert.has_no.errors(function()
					result = template_mod.resolve_placeholders({ "- [ ] タスク {{context}}" }, { context = "100%" })
				end)
				assert.is_not_nil(result[1]:find("@100%", 1, true), vim.inspect(result[1]))
			end
		)

		it(
			"project/context以外の{{name}}(本文への単純置換)の値に%が含まれてもエラーにならない",
			function()
				local result
				assert.has_no.errors(function()
					result = template_mod.resolve_placeholders({ "- [ ] {{note}}タスク" }, { note = "進捗50%" })
				end)
				assert.is_not_nil(result[1]:find("進捗50%タスク", 1, true), vim.inspect(result[1]))
			end
		)

		it(
			"値がgsubのキャプチャ参照として解釈されうる文字列(%1)でもエラーにならず、そのまま現れる",
			function()
				local result
				assert.has_no.errors(function()
					result = template_mod.resolve_placeholders({ "- [ ] {{note}}タスク" }, { note = "%1" })
				end)
				assert.is_not_nil(result[1]:find("%1タスク", 1, true), vim.inspect(result[1]))
			end
		)
	end)

	describe("extract_task_lines の第3引数(placeholder_values)", function()
		it("{{project}}を解決してからNON_INHERITABLE_TAGSの除去とserializeが行われる", function()
			local result = template_mod.extract_task_lines({ "- [ ] タスク {{project}}" }, nil, { project = "acme" })
			local task = task_mod.parse(result[1])
			assert.are.same("acme", task.project)
			assert.is_not_nil(task.id)
		end)

		it("placeholder_valuesとbase_time(due:相対指定)は独立して両方効く", function()
			local base_time = os.time({ year = 2024, month = 1, day = 10, hour = 12 })
			local result = template_mod.extract_task_lines(
				{ "- [ ] タスク {{project}} due:+3d" },
				base_time,
				{ project = "acme" }
			)
			local task = task_mod.parse(result[1])
			assert.are.same("acme", task.project)
			assert.are.same("2024-01-13", task.due)
		end)
	end)

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

		it("placeholder_valuesを渡すと{{project}}が解決されてinbox.mdへ追記される", function()
			vim.fn.writefile({ "# Inbox", "" }, inbox_path)
			vim.fn.writefile({
				"- [ ] 提案書作成 {{project}}",
			}, templates_dir .. "/with-project.md")

			local ok = template_mod.insert_template_tasks("with-project", nil, { project = "acme" })
			assert.is_true(ok)

			local lines = io_mod.read_lines(inbox_path)
			local task = task_mod.parse(lines[3])
			assert.are.same("acme", task.project)
		end)

		-- バグ2: 呼び出し元が既に読み込み済みの行を第4引数(lines)として渡せるように
		-- したい(将来の呼び出し元がテンプレートファイルを二重に読み込まないようにするため)。
		-- lines が渡された場合はディスクを一切読まずにその行から処理し、省略時は
		-- 従来通りディスクから読む(後方互換)。
		describe(
			"insert_template_tasks の第4引数(lines)でディスクを再読み込みしない(バグ2)",
			function()
				it(
					"lines を渡すと、ディスク上にテンプレートファイルが無くてもそのlinesから処理される",
					function()
						vim.fn.writefile({ "# Inbox", "" }, inbox_path)

						local ok = template_mod.insert_template_tasks(
							"does-not-exist-on-disk",
							nil,
							nil,
							{ "- [ ] linesから来たタスク" }
						)
						assert.is_true(ok)

						local lines = io_mod.read_lines(inbox_path)
						local task = task_mod.parse(lines[3])
						assert.are.same("linesから来たタスク", task.content)
					end
				)

				it(
					"lines を渡すと、同名のテンプレートファイルがディスクにあってもその内容は使われない",
					function()
						vim.fn.writefile({ "# Inbox", "" }, inbox_path)
						vim.fn.writefile({ "- [ ] ディスク上のタスク" }, templates_dir .. "/dup-check.md")

						local ok = template_mod.insert_template_tasks(
							"dup-check",
							nil,
							nil,
							{ "- [ ] 引数で渡したタスク" }
						)
						assert.is_true(ok)

						local lines = io_mod.read_lines(inbox_path)
						local task = task_mod.parse(lines[3])
						assert.are.same("引数で渡したタスク", task.content)
					end
				)
			end
		)

		-- バグ3: 内部で呼ぶ io_mod.write_lines が失敗(error()を投げる)した場合、
		-- そのエラーが insert_template_tasks の外まで無捕捉のまま伝播してしまう。
		-- 修正後は失敗してもエラーを外へ伝播させず、falseを返すべき。
		describe("insert_template_tasks の書き込み失敗時の挙動(バグ3)", function()
			it("io_mod.write_lines が失敗してもエラーを伝播させずfalseを返す", function()
				vim.fn.writefile({ "# Inbox", "" }, inbox_path)
				vim.fn.writefile({ "- [ ] 新規タスク" }, templates_dir .. "/write-fail.md")

				local original_write_lines = io_mod.write_lines
				io_mod.write_lines = function()
					error("simulated write failure")
				end

				local pcall_ok, result = pcall(function()
					return template_mod.insert_template_tasks("write-fail")
				end)

				-- 何が起きてもモンキーパッチは必ず元へ戻す
				io_mod.write_lines = original_write_lines

				assert.is_true(
					pcall_ok,
					"insert_template_tasks がエラーを外へ伝播させた: " .. tostring(result)
				)
				assert.is_false(result)
			end)
		end)
	end)
end)
