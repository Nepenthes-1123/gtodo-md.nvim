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

function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", M.defaults, opts)
	M.sections = vim.tbl_deep_extend("force", M.default_sections, opts.sections or {})
	-- ディレクトリが存在しない場合は作成
	local projects_dir = M.options.data_dir .. "/projects"
	if vim.fn.isdirectory(projects_dir) == 0 then
		vim.fn.mkdir(projects_dir, "p")
	end
end

-- key(TODAY/NEXT/WAITING/SOMEDAY)に対応する、見出しとして現在有効な
-- 名称候補を返す。カスタム名を設定している場合は [カスタム名, デフォルト名]
-- の順(カスタム名が優先)、設定していない場合はデフォルト名のみを返す。
function M.section_aliases(key)
	local custom = M.sections[key]
	local default = M.default_sections[key]
	if custom ~= default then
		return { custom, default }
	end
	return { custom }
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
