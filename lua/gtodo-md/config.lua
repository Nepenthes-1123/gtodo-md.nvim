local M = {}

M.defaults = {
	data_dir = vim.fn.stdpath("data") .. "/gtodo-md", -- デフォルトはNeovimのデータディレクトリ
	use_default_keymaps = true,
	picker = "auto", -- ピッカー指定 ("auto" | "snacks" | "telescope" | "fzf-lua" | "builtin")
	keymap_prefix = "<Leader>t", -- キーマップ of プレフィックス接頭辞
	due_notification_cooldown = 1800, -- 期限切れ通知の最小間隔（秒）。デフォルト30分
	due_notification_persist = true, -- trueでNeovim終了後も時間を維持、falseで起動中のみ
	auto_move_inbox_to_today = true, -- Inboxの期日到達タスクを自動でTodayに移動するかどうか
	waiting_warning_days = 2, -- Waitingタスクの期限警告日数
	enable_waiting_warning = true, -- Waitingタスクの期限警告通知を有効にするか
	waiting_warning_interval = 3600, -- Waitingタスク警告のチェック間隔（秒）。デフォルト1時間
	enable_project_progress = true, -- プロジェクトファイル最下部に進捗バーを表示するかどうか
	-- todo/inbox/done/cancelled のフローティングウィンドウ、および Queue ビューが
	-- 共有する横幅/高さの比率(#151)。画面(vim.o.columns/vim.o.lines)に対する割合。
	float_width_ratio = 0.8,
	float_height_ratio = 0.8,
	-- カンバンビュー専用の横幅/高さ比率(#151)。上記の float_*_ratio とはあえて
	-- 別のキーにしてある — 同じ値を共有すると、「todo.mdのポップアップを
	-- 小さめにしたい」という意図の設定が、意図せずカンバンの列数まで減らして
	-- しまう副作用が起きるため(カンバンは列数を確保するためになるべく画面全体を
	-- 使いたく、単一フロートより広めの既定値にしている)。
	kanban_width_ratio = 0.9,
	kanban_height_ratio = 0.8,
	-- conceal で隠す `key:value` 形式のタグ名。既定は `id` のみ(従来の挙動)。
	-- 指定できるのは id / created / due / wait / completed_at / done / cancelled / from。
	-- `+project`/`@context` は `key:value` 形式ではないため対象外。
	-- 隠しても行の実体は変わらず、検索や grep はこれまで通り効く。
	-- カーソルがその行にある間は concealcursor が空のため自動的に見える。
	conceal_tags = { "id" },
}

M.options = {}

-- デフォルトのセクション名。#94: setup({sections=...})でカスタム名を設定
-- できるが、この名前は常にエイリアスとして受理され続ける(io.luaのパース時に
-- 正規化、init.luaのBufWritePreバリデーションで許容)。既存のtodo.mdの
-- 見出しをユーザーに手動でリネームさせないための設計。
M.default_sections = {
	TODAY = "Today",
	NEXT = "Next",
	WAITING = "Waiting",
	SOMEDAY = "Someday",
}

-- todo.md 内でのセクションの表示・走査順の正本。M.default_sections はキーが
-- 名前を指す連想テーブルで順序を持たないため、順序が必要な箇所(初期テンプレート
-- 生成・フォールバックのsection_order・繰り込み時の走査順)はここから導出する。
M.section_order = { "TODAY", "NEXT", "WAITING", "SOMEDAY" }

M.sections = vim.tbl_extend("force", {}, M.default_sections)

-- 前回の setup() で使われていたセクション名(section_aliases が一時的な
-- エイリアスとして参照する)。state.read_last_sections で永続化されたものを
-- setup() のたびに読み込む。
M.last_sections = {}

-- 使えないセクション名をデフォルトへ差し戻す。
--
-- 空文字や非文字列をそのまま通すと、`ensure_files` が `## ` という見出しの無い
-- todo.md を作る一方で `section_aliases` はデフォルト名しか候補に返さないため、
-- 必須セクションが永遠に見つからず**保存が恒久的にブロックされる**。しかも
-- `missing_todo_sections` が組み立てるエラーメッセージも `## ` になるので、
-- ユーザーには何が不足しているのか読み取れない。
-- 設定ミスを黙って壊れた状態にせず、デフォルトへ戻したうえで理由を通知する。
local function sanitize_sections(sections)
	local sanitized = {}
	local rejected = {}
	for key, default_name in pairs(M.default_sections) do
		local name = sections[key]
		if type(name) ~= "string" or vim.trim(name) == "" then
			table.insert(rejected, key)
			sanitized[key] = default_name
		else
			sanitized[key] = vim.trim(name)
		end
	end
	if #rejected > 0 then
		table.sort(rejected)
		vim.notify(
			string.format(
				"[gtodo-md] section names must be non-empty strings; falling back to defaults for: %s",
				table.concat(rejected, ", ")
			),
			vim.log.levels.ERROR
		)
	end
	return sanitized
end

function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", M.defaults, opts)
	-- ディレクトリが存在しない場合は作成。
	-- 失敗を握り潰してはならない — 作成できないまま進むと、以降あらゆる書き込みが
	-- 失敗し続けるのに原因がどこにも表示されず、ユーザーには「保存が効かない」と
	-- しか見えない。ここで一度だけ通知して原因を特定可能にする。
	local projects_dir = M.options.data_dir .. "/projects"
	-- mkdir() は失敗時に 0 を返すが、書き込み不可のパス等では例外も投げうる。
	if not require("gtodo-md.utils").ensure_dir(projects_dir) then
		vim.notify(string.format("[gtodo-md] failed to create data directory: %s", projects_dir), vim.log.levels.ERROR)
	end

	-- #94: セクション名をカスタム化・変更した直後は、ファイル側の見出しが
	-- まだ前回の名前のままであることが多い。前回の名前を読み込んでおき、
	-- section_aliases が一時的なエイリアスとして受理できるようにする。
	local state = require("gtodo-md.state")
	local last = state.read_last_sections()
	M.last_sections = (type(last) == "table") and last or {}

	M.sections = sanitize_sections(vim.tbl_deep_extend("force", M.default_sections, opts.sections or {}))

	state.write_last_sections(M.sections)
end

-- key(TODAY/NEXT/WAITING/SOMEDAY)に対応する、見出しとして現在有効な
-- 名称候補を返す。現在のカスタム名・デフォルト名に加え、前回の setup() で
-- 使われていた名前(まだ変更していないファイルの見出しとの互換用)も含む。
function M.section_aliases(key)
	local aliases = {}
	local seen = {}
	local function add(name)
		if name and name ~= "" and not seen[name] then
			seen[name] = true
			table.insert(aliases, name)
		end
	end
	add(M.sections[key])
	add(M.default_sections[key])
	add(M.last_sections[key])
	return aliases
end

-- オプション値を取得する。未設定の場合はデフォルト値を返す
function M.get(key)
	local val = M.options[key]
	if val == nil then
		return M.defaults[key]
	end
	return val
end

return M
