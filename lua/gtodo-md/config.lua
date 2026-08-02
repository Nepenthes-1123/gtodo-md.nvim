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

M.sections = vim.tbl_extend("force", {}, M.default_sections)

-- 前回の setup() で使われていたセクション名(section_aliases が一時的な
-- エイリアスとして参照する)。utils.read_last_sections で永続化されたものを
-- setup() のたびに読み込む。
M.last_sections = {}

function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", M.defaults, opts)
	-- ディレクトリが存在しない場合は作成
	local projects_dir = M.options.data_dir .. "/projects"
	if vim.fn.isdirectory(projects_dir) == 0 then
		vim.fn.mkdir(projects_dir, "p")
	end

	-- #94: セクション名をカスタム化・変更した直後は、ファイル側の見出しが
	-- まだ前回の名前のままであることが多い。前回の名前を読み込んでおき、
	-- section_aliases が一時的なエイリアスとして受理できるようにする。
	local utils = require("gtodo-md.utils")
	local last = utils.read_last_sections()
	M.last_sections = (type(last) == "table") and last or {}

	M.sections = vim.tbl_deep_extend("force", M.default_sections, opts.sections or {})

	utils.write_last_sections(M.sections)
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
