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

	it("新しいタグが空なら既存タグを除去する", function()
		assert.are.same("- [ ] Task", rewrite("- [ ] Task +work", "work", ""))
	end)

	it("既存タグを新しいタグへ置換する", function()
		assert.are.same("- [ ] Task +home", rewrite("- [ ] Task +work", "work", "home"))
	end)

	it("置換時は既存タグの後ろの空白を保持する", function()
		assert.are.same("- [ ] Task +home  ", rewrite("- [ ] Task +work  ", "work", "home"))
	end)

	it("既存タグが無ければ行末へ新規付与する", function()
		assert.are.same("- [ ] Task +home", rewrite("- [ ] Task", nil, "home"))
		assert.are.same("- [ ] Task +home", rewrite("- [ ] Task  ", nil, "home"))
	end)

	it("既存タグも新しいタグも無い場合は行を変更しない", function()
		assert.are.same("- [ ] Task", rewrite("- [ ] Task", nil, ""))
	end)

	it("既存タグと新しいタグが同じ場合は行を変更しない", function()
		assert.are.same("- [ ] Task +work", rewrite("- [ ] Task +work", "work", "work"))
	end)

	it("Luaパターンの特殊文字を含む既存タグでもリテラルとして扱う", function()
		assert.are.same("- [ ] Task", rewrite("- [ ] Task +a.b-c", "a.b-c", ""))
		assert.are.same("- [ ] Task +x", rewrite("- [ ] Task +a.b-c", "a.b-c", "x"))
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
