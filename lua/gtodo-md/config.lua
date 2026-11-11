local shared = require("gtodo-md.shared")

local M = {}

M.defaults = {
	-- デフォルトはNeovimのデータディレクトリ。setup() で指定しなければ、CLI/TUI と
	-- 共有する設定 (GTODO_DATA_DIR・config.json) が先に使われる(resolve_data_dir 参照)。
	data_dir = vim.fn.stdpath("data") .. "/gtodo-md",
	use_default_keymaps = true,
	picker = "auto", -- ピッカー指定 ("auto" | "snacks" | "telescope" | "fzf-lua" | "builtin")
	keymap_prefix = "<Leader>t", -- キーマップ of プレフィックス接頭辞
	due_notification_cooldown = 1800, -- 期限切れ通知の最小間隔（秒）。デフォルト30分
	due_notification_persist = true, -- trueでNeovim終了後も時間を維持、falseで起動中のみ
	-- Inboxの期日到達タスクを自動でTodayに移動するかどうか。
	-- <data_dir>/gtodo.json に書かれていれば、そちらが優先される。
	auto_move_inbox_to_today = true,
	waiting_warning_days = 2, -- Waitingタスクの期限警告日数
	enable_waiting_warning = true, -- Waitingタスクの期限警告通知を有効にするか
	waiting_warning_interval = 3600, -- Waitingタスク警告のチェック間隔（秒）。デフォルト1時間
	enable_project_progress = true, -- プロジェクトファイルのフロントマター直下に進捗バーを表示するかどうか
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

-- 直前の setup() で、共有設定と重なる項目の値をどこから取ったか。
-- "setup()"・"default"・"GTODO_DATA_DIR"、または値を決めたファイルのパスが入る。
-- 「setup() に書いた値が効かない」ときに、:checkhealth で理由を確かめられるようにする。
M.sources = {}

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

local function notify(msg, level)
	vim.notify("[gtodo-md] " .. msg, level)
end

-- 他のセクションと同じ見出しを指す名前を持つキーを、キー名の昇順で返す。
--
-- 2つのキーが同じ見出しを指すと、`parse_markdown` が両方の見出しを同じ名前へ
-- 正規化して1つのセクションとして読み、`write_todo_file` がそのまま1つの見出しで
-- 書き戻す。セクションの区別がディスクから無通知で失われる。
-- 他のキーのデフォルト名も、そのキーが別の名前へ変えていても重複として扱う —
-- デフォルト名は別名として受理され続けるため(`section_aliases`)、既存ファイルの
-- その見出しがどちらのセクションか決まらなくなる。
--
-- デフォルト名のままのキーは返さない。利用者が設定した名前ではなく、
-- 差し戻しても何も変わらないため、通知に挙げると直す場所を誤らせる。
local function conflicting_section_keys(names)
	local keys = {}
	for key, name in pairs(names) do
		if name ~= M.default_sections[key] then
			for other, other_default in pairs(M.default_sections) do
				if other ~= key and (names[other] == name or other_default == name) then
					table.insert(keys, key)
					break
				end
			end
		end
	end
	table.sort(keys)
	return keys
end

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
		notify(
			"section names must be non-empty strings; falling back to defaults for: " .. table.concat(rejected, ", "),
			vim.log.levels.ERROR
		)
	end

	-- 判定は差し戻す前の名前どうしで行い、差し戻しは最後にまとめて行う。途中で
	-- 差し戻すと、同じ名前の2つのうち `pairs` が先に返した方だけが差し戻され、
	-- もう一方がその名前を使い続ける。
	local duplicated = conflicting_section_keys(sanitized)
	if #duplicated > 0 then
		for _, key in ipairs(duplicated) do
			sanitized[key] = M.default_sections[key]
		end
		notify(
			"section names must be unique and must not reuse another section's default name; "
				.. "falling back to defaults for: "
				.. table.concat(duplicated, ", "),
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

-- 2つのパスが同じ場所を指すか。末尾の区切りや `..` のような書き方の違いは無視する。
local function same_path(a, b)
	local function canonical(path)
		return vim.fs.normalize(vim.fs.abspath(path))
	end
	return canonical(a) == canonical(b)
end

-- data_dir を決め、その値をどこから取ったかと併せて返す。
--
-- 優先順は setup() → GTODO_DATA_DIR → config.json → 既定。
-- setup() の指定は CLI の `--data-dir` と同じ「その場での明示」として扱い、共有設定より
-- 優先する。プロジェクトごとに data_dir を変える設定やテスト用の一時ディレクトリが、
-- 利用者全体の config.json に上書きされないようにするため。
-- その代わり、CLI が(--data-dir 無しで)見る場所と食い違っていれば警告する。
local function resolve_data_dir(explicit)
	local env, windows = shared.process_env, shared.is_windows()

	-- CLI が --data-dir 無しで使う場所と、それを決めたもの。
	local shared_dir, shared_source
	if env("GTODO_DATA_DIR") then
		-- CLI は GTODO_DATA_DIR があれば config.json を読まない。こちらだけ読むと、
		-- CLI では問題にならない config.json の誤りを起動のたびに通知することになる。
		local dir, err = shared.env_data_dir(env, windows)
		if dir then
			shared_dir, shared_source = dir, "GTODO_DATA_DIR"
		else
			notify("GTODO_DATA_DIR: " .. err, vim.log.levels.ERROR)
		end
	else
		local path, explicit_path = shared.config_path(env, windows)
		if path then
			local result = shared.read_config(path, explicit_path, env, windows)
			for _, warning in ipairs(result.warnings) do
				notify(warning, vim.log.levels.WARN)
			end
			-- CLI はこのファイルで止まる。setup() の指定で動けていても、直すべきことは伝える。
			if result.err then
				notify(result.err .. "; ignoring it", vim.log.levels.ERROR)
			elseif result.data_dir then
				shared_dir, shared_source = result.data_dir, path
			end
		end
	end

	if explicit ~= nil then
		if shared_dir and type(explicit) == "string" and not same_path(explicit, shared_dir) then
			notify(
				string.format(
					"data_dir from setup() (%s) differs from %s (%s), which the gtodo CLI uses; "
						.. "remove data_dir from setup() to share the same directory",
					explicit,
					shared_source,
					shared_dir
				),
				vim.log.levels.WARN
			)
		end
		return explicit, "setup()"
	end
	if shared_dir then
		return shared_dir, shared_source
	end
	return M.defaults.data_dir, "default"
end

-- gtodo.json の "sections" から4つのセクション名を決める。使えなければ nil と理由を返す。
--
-- 書かれていないセクションは、setup() の名前ではなくデフォルト名にする。CLI がそう読むため。
-- そこだけ setup() の名前を使うと、そのセクションの見出しを CLI はデフォルト名で、
-- こちらは setup() の名前で書き、互いが書くたびに見出しが入れ替わる。
local function sections_from_settings(file_sections)
	local names = {}
	for _, key in ipairs(M.section_order) do
		local name = file_sections[key]
		if name == nil then
			names[key] = M.default_sections[key]
		else
			names[key] = vim.trim(name)
			if names[key] == "" then
				return nil, string.format('section name for "%s" must not be empty', key:lower())
			end
		end
	end
	local duplicated = conflicting_section_keys(names)
	if #duplicated > 0 then
		return nil,
			"section names must be unique and must not reuse another section's default name: " .. table
				.concat(duplicated, ", ")
				:lower()
	end
	return names
end

-- <data_dir>/gtodo.json を読み、使える設定を返す。
-- 戻り値は { path, sections = 4つの名前 | nil, auto_move_inbox_to_today = boolean | nil }。
--
-- 使えないファイルは、読めた項目も含めて全体を無いものとして扱う。CLI はこのファイルで
-- 止まるので、読めた項目だけ使うと、CLI が一度も使っていない値でこちらだけが動く。
local function read_data_settings(data_dir)
	local path = data_dir .. "/gtodo.json"
	local result = shared.read_settings(path, M.section_order)
	for _, warning in ipairs(result.warnings) do
		notify(warning, vim.log.levels.WARN)
	end

	local err = result.err
	local sections
	if not err and result.sections then
		local reason
		sections, reason = sections_from_settings(result.sections)
		if not sections then
			err = string.format("%s is not a valid settings file: %s", path, reason)
		end
	end
	if err then
		notify(err .. "; ignoring it", vim.log.levels.ERROR)
		return { path = path }
	end
	return { path = path, sections = sections, auto_move_inbox_to_today = result.auto_move_inbox_to_today }
end

-- gtodo.json がセクション名を決めたとき、使われなかった setup() の名前を知らせる。
-- 黙って無視すると、setup() を書き換えても効かない理由が利用者に分からない。
local function warn_ignored_section_names(configured, settings)
	if type(configured) ~= "table" then
		return
	end
	local ignored = {}
	for _, key in ipairs(M.section_order) do
		local name = configured[key]
		if name ~= nil and not (type(name) == "string" and vim.trim(name) == settings.sections[key]) then
			table.insert(ignored, key)
		end
	end
	if #ignored > 0 then
		table.sort(ignored)
		notify(
			string.format(
				"section names from setup() are ignored for: %s; %s sets the section names",
				table.concat(ignored, ", "),
				settings.path
			),
			vim.log.levels.WARN
		)
	end
end

function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", M.defaults, opts)
	M.options.border = sanitize_border(M.options.border)
	M.sources = {}
	M.options.data_dir, M.sources.data_dir = resolve_data_dir(opts.data_dir)
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

	-- gtodo.json に書かれた項目は、setup() の値より優先する。data_dir と違い、
	-- こちらは「そのディレクトリのデータの形」であり、同じディレクトリを触るツールが
	-- 別の値を使うと、互いが書くたびに見出しが書き換わり続けるため。
	local settings = read_data_settings(M.options.data_dir)

	if settings.sections then
		M.sections = settings.sections
		M.sources.sections = settings.path
		warn_ignored_section_names(opts.sections, settings)
	else
		M.sections = sanitize_sections(vim.tbl_deep_extend("force", M.default_sections, opts.sections or {}))
		M.sources.sections = opts.sections ~= nil and "setup()" or "default"
	end

	local auto_move = settings.auto_move_inbox_to_today
	if auto_move ~= nil then
		if opts.auto_move_inbox_to_today ~= nil and opts.auto_move_inbox_to_today ~= auto_move then
			notify(
				string.format(
					"auto_move_inbox_to_today from setup() (%s) is ignored; %s sets it to %s",
					tostring(opts.auto_move_inbox_to_today),
					settings.path,
					tostring(auto_move)
				),
				vim.log.levels.WARN
			)
		end
		M.options.auto_move_inbox_to_today = auto_move
		M.sources.auto_move_inbox_to_today = settings.path
	else
		M.sources.auto_move_inbox_to_today = opts.auto_move_inbox_to_today ~= nil and "setup()" or "default"
	end

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

-- 見出しの名前(前後の空白は除いたもの)が指すセクションのキーを返す。どれでもなければ nil。
--
-- 全セクションの現在の名前 → デフォルト名 → 前回の名前、の順に照合する。
-- キーごとに section_aliases をまとめて照合してはならない。あるセクションの前回の名前が
-- 別のセクションの現在の名前やデフォルト名と同じとき(名前を入れ替えた直後など)、
-- どちらのセクションとして読むかが pairs の順で変わり、見出しが別のセクションへ移る。
-- 現在の名前が他のセクションの現在の名前・デフォルト名と重なる設定は、setup() が
-- 差し戻しているため、前の2段では1つに決まる。CLI (gtodo) も同じ順で照合する。
function M.section_key_of(heading)
	for _, names in ipairs({ M.sections, M.default_sections, M.last_sections }) do
		for _, key in ipairs(M.section_order) do
			local name = names[key]
			if type(name) == "string" and name ~= "" and name == heading then
				return key
			end
		end
	end
	return nil
end

-- 見出しの名前を、そのセクションの現在の名前へ揃える。管理対象のセクションでなければそのまま返す。
-- 既存ファイルの見出しがデフォルト名や前回の名前のままでも、読むときに現在の名前として扱い、
-- 書くときに現在の名前で書き戻す(見出しを利用者に手でリネームさせないため、#94)。
function M.normalize_section_name(heading)
	local key = M.section_key_of(heading)
	if key then
		return M.sections[key]
	end
	return heading
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
