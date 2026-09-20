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
	-- setup()での部分上書き(例: setup({float_ratio={width=0.5}}))はvim.tbl_deep_extend
	-- がネストしたテーブルを再帰的にマージするため、指定しなかったheightは
	-- デフォルト値のまま残る(sectionsのような専用サニタイズは不要)。
	float_ratio = { width = 0.8, height = 0.8 },
	-- カンバンビュー専用の横幅/高さ比率(#151)。上記の float_ratio とはあえて
	-- 別のキーにしてある — 同じ値を共有すると、「todo.mdのポップアップを
	-- 小さめにしたい」という意図の設定が、意図せずカンバンの列数まで減らして
	-- しまう副作用が起きるため(カンバンは列数を確保するためになるべく画面全体を
	-- 使いたく、単一フロートより広めの既定値にしている)。
	kanban_ratio = { width = 0.9, height = 0.8 },
	-- このプラグインが開くフローティングウィンドウ(todo/inbox/done/cancelled の
	-- フロート、Queue、カンバンの各列、タスク分割のポップアップ)の罫線スタイル。
	-- nvim_open_win の border と同じ値を取る('winborder' の値一覧を参照)。
	--
	-- 既定の "auto" は次の順で解決する(M.resolve_border 参照):
	--   1. ここに具体的な値が設定されていればそれ
	--   2. Neovim 全体の 'winborder' が設定されていればそれに委ねる
	--   3. どちらも無ければ "rounded"
	-- ユーザーが設定している項目があればそちらを優先し、無ければ見た目の
	-- 既定を用意する、という方針。
	border = "auto",
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

-- nvim_open_win の border が受け付けるプリセット('winborder' と同じ一覧)。
-- カスタム指定は 8 要素の配列で渡せるため、テーブルは値を検証せず通す
-- (中身の妥当性は nvim_open_win 側が判定する)。
local BORDER_PRESETS = {
	-- "auto" は nvim_open_win の値ではなく、このプラグインの解決方式を表す番兵。
	auto = true,
	bold = true,
	double = true,
	none = true,
	rounded = true,
	shadow = true,
	single = true,
	solid = true,
	[""] = true,
}

-- 使えない border を既定へ差し戻す。
--
-- 素通しにすると nvim_open_win が例外を投げ、フロートを開こうとするたびに
-- 生のエラーが表面化する(ui/float.lua は pcall していない)。設定ミスを黙って
-- 壊れた状態にせず、既定へ戻したうえで理由を通知する(sanitize_sections と同じ方針)。
local function sanitize_border(border)
	if type(border) == "table" then
		return border
	end
	if type(border) == "string" and BORDER_PRESETS[border] then
		return border
	end
	vim.notify(
		string.format("[gtodo-md] invalid border %s; falling back to %q", vim.inspect(border), M.defaults.border),
		vim.log.levels.ERROR
	)
	return M.defaults.border
end

function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", M.defaults, opts)
	M.options.border = sanitize_border(M.options.border)
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

-- nvim_open_win の border へ渡す値を解決する。
-- nil を返した場合は border を**渡さない**こと。Neovim が 'winborder' を適用する。
--
-- 解決順は border のコメントを参照。ユーザーが 'winborder' を設定している
-- 環境では、こちらが border を明示すると 'winborder' を上書きしてしまうため、
-- あえて渡さずに委ねる。
function M.resolve_border()
	local configured = M.get("border")
	if configured ~= "auto" then
		return configured
	end
	if vim.o.winborder ~= "" then
		return nil
	end
	return "rounded"
end

-- 実際に描画される罫線の値を返す。カンバンが罫線の消費幅を見積もるために使う
-- (resolve_border が nil を返す場合、実際に効くのは 'winborder' の値)。
function M.effective_border()
	local resolved = M.resolve_border()
	if resolved ~= nil then
		return resolved
	end
	return vim.o.winborder
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
