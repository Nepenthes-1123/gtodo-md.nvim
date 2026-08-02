-- 保存時バリデーションのルールを純関数として単体テストする。
-- autocmd 経由の発火(BufWritePre)を伴う挙動は bufwritepre_scope_spec /
-- config_sections_spec が担保しているため、ここでは validate.lua の
-- 判定ロジックそのものだけを対象とする。

local config = require("gtodo-md.config")
local validate = require("gtodo-md.validate")

describe("validate", function()
	local data_dir

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		config.setup({ data_dir = data_dir }) -- 次のテストへ影響しないよう既定に戻す
		vim.fn.delete(data_dir, "rf")
	end)

	describe("missing_todo_sections", function()
		local function full_todo()
			return {
				"# Todo",
				"",
				"## Today",
				"",
				"## Next",
				"",
				"## Waiting",
				"",
				"## Someday",
				"",
			}
		end

		it("必須セクションが揃っていれば空リストを返す", function()
			assert.are.same({}, validate.missing_todo_sections(full_todo()))
		end)

		it("不足しているセクションを見出し文字列として返す", function()
			local lines = { "# Todo", "", "## Next", "", "## Someday", "" }
			assert.are.same({ "## Today", "## Waiting" }, validate.missing_todo_sections(lines))
		end)

		it("見出しの前後の空白は無視して照合する", function()
			local lines = { "##   Today  ", "## Next", "## Waiting", "## Someday" }
			assert.are.same({}, validate.missing_todo_sections(lines))
		end)

		it("### 見出し(サブセクション)はセクションとして数えない", function()
			local lines = { "### Today", "## Next", "## Waiting", "## Someday" }
			assert.are.same({ "## Today" }, validate.missing_todo_sections(lines))
		end)

		it("カスタム名を設定してもデフォルト名の見出しを受理する (#94)", function()
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
			assert.are.same({}, validate.missing_todo_sections(full_todo()))
		end)

		it("カスタム名の見出しも受理する (#94)", function()
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
			local lines = { "## 今日", "## Next", "## Waiting", "## Someday" }
			assert.are.same({}, validate.missing_todo_sections(lines))
		end)

		it("不足時のメッセージには現在のカスタム名を使う (#94)", function()
			config.setup({ data_dir = data_dir, sections = { TODAY = "今日" } })
			local lines = { "## Next", "## Waiting", "## Someday" }
			assert.are.same({ "## 今日" }, validate.missing_todo_sections(lines))
		end)
	end)

	describe("has_required_header", function()
		it("必須ヘッダーがあればtrueを返す", function()
			assert.is_true(validate.has_required_header({ "# Inbox", "", "- [ ] a" }, "# Inbox"))
		end)

		it("先頭行でなくてもヘッダーがあればtrueを返す", function()
			assert.is_true(validate.has_required_header({ "", "# Done" }, "# Done"))
		end)

		it("必須ヘッダーが無ければfalseを返す", function()
			assert.is_false(validate.has_required_header({ "no header here" }, "# Inbox"))
		end)

		it("空バッファではfalseを返す", function()
			assert.is_false(validate.has_required_header({}, "# Cancelled"))
		end)
	end)

	describe("collect_history_sections", function()
		it("## YYYY-MM 見出しを集合として返す", function()
			local lines = { "# Done", "", "## 2026-08", "", "## 2026-07", "" }
			assert.are.same({ ["2026-08"] = true, ["2026-07"] = true }, validate.collect_history_sections(lines))
		end)

		it("年月形式でない見出しは含めない", function()
			local lines = { "## Today", "## 2026-8", "## 2026-08-01", "### 2026-08" }
			assert.are.same({}, validate.collect_history_sections(lines))
		end)
	end)

	describe("missing_history_sections", function()
		it("読み込み時に存在した見出しが残っていれば空リストを返す", function()
			local lines = { "# Done", "## 2026-08", "## 2026-07" }
			local original = { ["2026-08"] = true, ["2026-07"] = true }
			assert.are.same({}, validate.missing_history_sections(lines, original))
		end)

		it("削除された見出しを検出する", function()
			local lines = { "# Done", "## 2026-08" }
			local original = { ["2026-08"] = true, ["2026-07"] = true }
			assert.are.same({ "## 2026-07" }, validate.missing_history_sections(lines, original))
		end)

		it("新しい見出しが増えているだけなら不足扱いしない", function()
			local lines = { "# Done", "## 2026-08", "## 2026-09" }
			assert.are.same({}, validate.missing_history_sections(lines, { ["2026-08"] = true }))
		end)

		it("original_secs が nil でもエラーにならない", function()
			assert.are.same({}, validate.missing_history_sections({ "# Done" }, nil))
		end)
	end)

	describe("extract_frontmatter_created", function()
		it("フロントマター内のcreatedの値を返す", function()
			local lines = { "---", "title: foo", "created: 2026-08-01", "---", "本文" }
			assert.equals("2026-08-01", validate.extract_frontmatter_created(lines))
		end)

		it("値の前後の空白を除去する", function()
			local lines = { "---", "created:   2026-08-01  ", "---" }
			assert.equals("2026-08-01", validate.extract_frontmatter_created(lines))
		end)

		it("フロントマターが無ければnilを返す", function()
			assert.is_nil(validate.extract_frontmatter_created({ "# foo", "created: 2026-08-01" }))
		end)

		it("終端の --- が無ければnilを返す", function()
			assert.is_nil(validate.extract_frontmatter_created({ "---", "created: 2026-08-01" }))
		end)

		it("フロントマター外のcreatedは拾わない", function()
			local lines = { "---", "title: foo", "---", "created: 2026-08-01" }
			assert.is_nil(validate.extract_frontmatter_created(lines))
		end)
	end)

	describe("validate_project_frontmatter", function()
		local function frontmatter(overrides)
			local values = vim.tbl_extend("force", {
				title = "サンプル",
				tag = "sample",
				created = "2026-08-01",
				due = "2026-09-01",
				status = "active",
				members = "topaz",
			}, overrides or {})

			local lines = { "---" }
			for _, key in ipairs({ "title", "tag", "created", "due", "status", "members" }) do
				if values[key] ~= false then
					table.insert(lines, key .. ": " .. values[key])
				end
			end
			table.insert(lines, "---")
			table.insert(lines, "")
			return lines
		end

		it("必須項目が揃いtagがファイル名と一致していれば妥当", function()
			assert.are.same({}, validate.validate_project_frontmatter(frontmatter(), "sample", nil))
		end)

		it("createdが読み込み時と同じなら妥当", function()
			local errors = validate.validate_project_frontmatter(frontmatter(), "sample", "2026-08-01")
			assert.are.same({}, errors)
		end)

		it("createdの変更を検出する", function()
			local lines = frontmatter({ created = "2026-01-01" })
			local errors = validate.validate_project_frontmatter(lines, "sample", "2026-08-01")
			assert.are.same({ "created (作成日) の変更は禁止されています" }, errors)
		end)

		it("original_createdがnilならcreatedの値は変更扱いしない", function()
			local lines = frontmatter({ created = "2026-01-01" })
			assert.are.same({}, validate.validate_project_frontmatter(lines, "sample", nil))
		end)

		it("tagがファイル名と一致しない場合を検出する", function()
			local errors = validate.validate_project_frontmatter(frontmatter(), "other", nil)
			assert.are.same({ "tag の値がファイル名 (other) と一致していません" }, errors)
		end)

		it("必須項目の不足を検出する", function()
			local lines = frontmatter({ due = false })
			local errors = validate.validate_project_frontmatter(lines, "sample", nil)
			assert.equals(1, #errors)
			assert.equals("必須項目が不足しています (due)", errors[1])
		end)

		it("フロントマターが全く無い場合はエラーを返す", function()
			local errors = validate.validate_project_frontmatter({ "本文のみ" }, "sample", nil)
			assert.is_true(#errors > 0)
		end)

		it("終端の --- が無ければエラーを返す", function()
			local lines = { "---", "title: サンプル", "tag: sample" }
			assert.is_true(#validate.validate_project_frontmatter(lines, "sample", nil) > 0)
		end)

		it("エラーは created / tag / 必須項目 の順に並ぶ", function()
			local lines = frontmatter({ created = "2026-01-01", tag = "other", members = false })
			local errors = validate.validate_project_frontmatter(lines, "sample", "2026-08-01")
			assert.equals(3, #errors)
			assert.equals("created (作成日) の変更は禁止されています", errors[1])
			assert.equals("tag の値がファイル名 (sample) と一致していません", errors[2])
			assert.equals("必須項目が不足しています (members)", errors[3])
		end)
	end)
end)
