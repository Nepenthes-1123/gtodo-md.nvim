-- split.lua から切り出した純関数の単体テスト。
-- これらはバッファやウィンドウに触れず、入出力が文字列だけで決まるため
-- split_current_task() 全体を起動せずに検証できる。

local split_mod = require("gtodo-md.split")

describe("split._sanitize_project_tag", function()
	local sanitize = split_mod._sanitize_project_tag

	it("通常のタグはそのまま返す", function()
		assert.are.same("work", sanitize("work"))
	end)

	it("先頭・末尾のドットを除去する", function()
		assert.are.same("hidden", sanitize(".hidden."))
		assert.are.same("a.b", sanitize("..a.b.."))
	end)

	it("ファイル名に使えない記号をハイフンへ置換する", function()
		assert.are.same("a-b-c-d-e-f-g-h-i-j", sanitize('a<b>c:d"e/f\\g|h?i*j'))
	end)

	it("空白をハイフン化し、連続するハイフンを1つへ圧縮する", function()
		assert.are.same("my-project", sanitize("my project"))
		assert.are.same("a-b", sanitize("a  --  b"))
	end)

	it(
		"正規化の結果が空になる入力では空文字を返す(中断判定は呼び出し元の責務)",
		function()
			assert.are.same("", sanitize("*"))
			assert.are.same("", sanitize("---"))
			assert.are.same("", sanitize("..."))
		end
	)

	it("DOS予約名には _proj サフィックスを付ける(大文字小文字を問わない)", function()
		assert.are.same("con_proj", sanitize("con"))
		assert.are.same("CON_proj", sanitize("CON"))
		assert.are.same("nul_proj", sanitize("nul"))
		assert.are.same("com4_proj", sanitize("com4"))
		assert.are.same("lpt3_proj", sanitize("lpt3"))
	end)

	it("DOS予約名の判定は最初のドットまでの部分に対して行う", function()
		assert.are.same("prn_proj.md", sanitize("prn.md"))
	end)

	it("予約名を含むだけの名前は変更しない", function()
		assert.are.same("console", sanitize("console"))
		assert.are.same("my-con", sanitize("my-con"))
	end)

	it("80文字を超えるタグはクランプする(文字数単位)", function()
		assert.are.same(string.rep("a", 80), sanitize(string.rep("a", 100)))
		-- マルチバイトでもバイト数ではなく文字数で切り詰める
		assert.are.same(80, vim.fn.strchars(sanitize(string.rep("あ", 100))))
	end)
end)

describe("split._rewrite_project_tag", function()
	local rewrite = split_mod._rewrite_project_tag

	-- 実運用の行は必ず `id:` を末尾に持つ。task.lua の serialize が付与するうえ、
	-- split_current_task も acquire_split_entry が先に走って id を発行するためである。
	-- 以前のテストは `+tag` が行の絶対最後にあるケースしか渡しておらず、
	-- 「+project の後ろに別のタグがあると行末アンカーがマッチせず黙って失敗する」
	-- 不具合を1つも検出できていなかった。

	it("既存タグを新しいタグへ置換する", function()
		assert.are.same("- [ ] Task +home id:a1b2c3", rewrite("- [ ] Task +work id:a1b2c3", "work", "home"))
	end)

	it("+project の後ろに他のタグが並んでいても置換できる", function()
		assert.are.same(
			"- [ ] Task +home @ctx due:2026-08-10 id:a1b2c3",
			rewrite("- [ ] Task +work @ctx due:2026-08-10 id:a1b2c3", "work", "home")
		)
	end)

	it("新しいタグが空なら既存タグを除去する", function()
		assert.are.same("- [ ] Task id:a1b2c3", rewrite("- [ ] Task +work id:a1b2c3", "work", ""))
	end)

	it("+project の後ろに他のタグが並んでいても除去できる", function()
		assert.are.same(
			"- [ ] Task @ctx due:2026-08-10 id:a1b2c3",
			rewrite("- [ ] Task +work @ctx due:2026-08-10 id:a1b2c3", "work", "")
		)
	end)

	it("既存タグが無ければ正本の位置へ新規付与する", function()
		assert.are.same("- [ ] Task +home id:a1b2c3", rewrite("- [ ] Task id:a1b2c3", nil, "home"))
	end)

	it("既存タグも新しいタグも無い場合は行を変更しない", function()
		assert.are.same("- [ ] Task id:a1b2c3", rewrite("- [ ] Task id:a1b2c3", nil, ""))
	end)

	it("既存タグと新しいタグが同じ場合は行を変更しない", function()
		-- 正規化のための書き換えも起こさないこと(呼び出し元が差分の有無で判断するため)
		assert.are.same("- [ ] Task +work", rewrite("- [ ] Task +work", "work", "work"))
	end)

	-- チェックボックス行は task.lua の parse/serialize へ委譲され、Lua パターンを
	-- 組み立てる処理(escape_lua_pattern / replace_project_token)には到達しない。
	-- タグ値がパターンとして誤解釈されないことを実際に確かめられるのは、
	-- **parse できない行**を渡したときだけである。
	-- チェックボックス行だけでこの観点をテストしたつもりになると、エスケープ処理が
	-- 完全に無検証のまま残る(実際にそうなっていた)。
	it(
		"Luaパターンの特殊文字を含む既存タグでもリテラルとして扱う(エスケープ経路)",
		function()
			assert.are.same("- 素の項目 +x trailing", rewrite("- 素の項目 +a.b-c trailing", "a.b-c", "x"))
			assert.are.same("- 素の項目 trailing", rewrite("- 素の項目 +a.b-c trailing", "a.b-c", ""))
			-- `%` は Lua パターンのエスケープ文字そのもの
			assert.are.same("- 素の項目 +x trailing", rewrite("- 素の項目 +a%b-c trailing", "a%b-c", "x"))
			-- `.` は「任意の1文字」。エスケープが漏れると `axbxc` 等にも誤ってマッチする
			assert.are.same("- 素の項目 +axbxc trailing", rewrite("- 素の項目 +axbxc trailing", "a.b.c", "x"))
		end
	)

	it("チェックボックス行でも特殊文字を含むタグを扱える(parse/serialize 経路)", function()
		assert.are.same("- [ ] Task id:a1b2c3", rewrite("- [ ] Task +a.b-c id:a1b2c3", "a.b-c", ""))
		assert.are.same("- [ ] Task +x id:a1b2c3", rewrite("- [ ] Task +a.b-c id:a1b2c3", "a.b-c", "x"))
	end)

	-- resolve_split_target はチェックボックス以外のリスト項目や引用符付きの行も通すため、
	-- task.lua で parse できない行はトークン置換で扱う。
	it("チェックボックスでないリスト項目でも置換できる", function()
		assert.are.same("- Plain item +home trailing", rewrite("- Plain item +work trailing", "work", "home"))
		assert.are.same("- Plain item trailing", rewrite("- Plain item +work trailing", "work", ""))
	end)

	it("引用符付きの行でも置換できる", function()
		assert.are.same("> - [ ] Quoted +home more", rewrite("> - [ ] Quoted +work more", "work", "home"))
	end)

	it("置換時は既存タグの後ろの空白を保持する(parse できない行)", function()
		assert.are.same("- Plain +home  ", rewrite("- Plain +work  ", "work", "home"))
	end)
end)

-- 親タスクのメタデータを子タスクへ継承する際、`id:` を引き継いではならない。
-- id は一意なタスク識別子であり、複製すると editor._find_task_idx が Primary の
-- 同定キーとして id 完全一致を最優先で使う設計上、別のタスクを操作してしまう。
describe("split._extract_metadata", function()
	local extract = split_mod._extract_metadata

	it("継承すべきタグは拾う", function()
		local meta = extract("- [ ] 親 +proj @home due:2026-08-10 created:2026-08-01")
		assert.is_true(vim.tbl_contains(meta, "+proj"))
		assert.is_true(vim.tbl_contains(meta, "@home"))
		assert.is_true(vim.tbl_contains(meta, "due:2026-08-10"))
		assert.is_true(vim.tbl_contains(meta, "created:2026-08-01"))
	end)

	it("id: は継承対象に含めない", function()
		local meta = extract("- [ ] 親 +proj due:2026-08-10 id:a1b2c3")
		for _, m in ipairs(meta) do
			assert.is_nil(m:match("^id:"), "id: が継承対象に混入している: " .. m)
		end
	end)

	it("完了・キャンセルの記録も継承しない", function()
		local meta = extract("- [x] 親 +proj completed_at:2026-08-01 done:2026-08-01 cancelled:2026-08-02")
		for _, m in ipairs(meta) do
			assert.is_nil(m:match("^completed_at:"), "completed_at: が混入: " .. m)
			assert.is_nil(m:match("^done:"), "done: が混入: " .. m)
			assert.is_nil(m:match("^cancelled:"), "cancelled: が混入: " .. m)
		end
	end)

	it("URL は除外したままにする", function()
		local meta = extract("- [ ] 親 https://example.com/x +proj")
		for _, m in ipairs(meta) do
			assert.is_nil(m:match("^https?:"))
		end
	end)
end)

describe("split._summarize_parent_text", function()
	local summarize = split_mod._summarize_parent_text

	it("リストマーカーとチェックボックスを除去する", function()
		assert.are.same("Buy milk", summarize("- [ ] Buy milk"))
		assert.are.same("Buy milk", summarize("  * [x] Buy milk"))
		assert.are.same("Buy milk", summarize("1. [ ] Buy milk"))
	end)

	it("引用(blockquote)のプレフィックスも除去する", function()
		assert.are.same("Quoted task", summarize("> - [ ] Quoted task"))
	end)

	it("+project / @context / #tag のメタデータを除去する", function()
		assert.are.same("Do it", summarize("- [ ] Do it +proj @home #tag"))
	end)

	it("key:value 形式のメタデータを除去する", function()
		assert.are.same("Do it", summarize("- [x] Do it +proj @home due:2024-01-01 id:abc123"))
	end)

	it("URL の http(s): は key:value とみなさず残す", function()
		assert.are.same("See https://example.com/x", summarize("- [ ] See https://example.com/x"))
		assert.are.same("See http://example.com", summarize("- [ ] See http://example.com due:2024-01-01"))
	end)

	it("40文字を超える場合は省略記号を付けて切り詰める", function()
		assert.are.same(string.rep("a", 40) .. "...", summarize("- [ ] " .. string.rep("a", 50)))
		assert.are.same(string.rep("a", 40), summarize("- [ ] " .. string.rep("a", 40)))
	end)

	it("リスト行でないテキストはそのまま返す", function()
		assert.are.same("Just text", summarize("Just text"))
	end)
end)
