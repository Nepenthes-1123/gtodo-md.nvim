local M = {}
local config = require("gtodo-md.config")
local task_mod = require("gtodo-md.task")

local cache = {
	todo_mtime = 0,
	inbox_mtime = 0,
	stats = { today = 0, inbox = 0 },
}

-- 高速にタスク数をカウントするAPI (Lualine等用)
--
-- この関数は副作用を持たない(ファイル書き込み・ロック取得・バッファリロードを行わない)。
-- statusline の再描画のたびに呼ばれるため、日次ロールオーバーの実行は
-- timer.lua の60秒タイマーおよび autocmd(FocusGained/BufEnter)側の責務とする。
function M.get_stats()
	local data_dir = config.get("data_dir")
	if not data_dir then
		return cache.stats
	end

	local todo_path = data_dir .. "/todo.md"
	local inbox_path = data_dir .. "/inbox.md"

	local todo_mtime = vim.fn.getftime(todo_path)
	local inbox_mtime = vim.fn.getftime(inbox_path)

	local needs_update = false
	if todo_mtime ~= cache.todo_mtime or inbox_mtime ~= cache.inbox_mtime then
		needs_update = true
	end

	if needs_update then
		local stats = { today = 0, inbox = 0 }

		-- todo.md から Today の未完了タスク数を高速カウント
		-- config.sections.TODAY(#94のセクション名カスタマイズ)に追従させる
		if vim.fn.filereadable(todo_path) == 1 then
			local today_pat = "^## " .. vim.pesc(config.sections.TODAY)
			local f = io.open(todo_path, "r")
			if f then
				local in_today = false
				for line in f:lines() do
					if line:match("^## ") then
						if line:match(today_pat) then
							in_today = true
						else
							in_today = false
						end
					end
					if in_today and task_mod.is_todo_line(line) then
						stats.today = stats.today + 1
					end
				end
				f:close()
			end
		end

		-- inbox.md から Inbox の未完了タスク数を高速カウント
		if vim.fn.filereadable(inbox_path) == 1 then
			local f = io.open(inbox_path, "r")
			if f then
				for line in f:lines() do
					if task_mod.is_todo_line(line) then
						stats.inbox = stats.inbox + 1
					end
				end
				f:close()
			end
		end

		cache.todo_mtime = todo_mtime
		cache.inbox_mtime = inbox_mtime
		cache.stats = stats
	end

	return cache.stats
end

-- あらゆるステータスラインプラグイン（および標準の statusline）で使える
-- 汎用的な文字列フォーマットを返すヘルパー関数
function M.get_statusline_string(opts)
	opts = vim.tbl_deep_extend("force", {
		icon_today = "📝",
		icon_inbox = "📥",
		icon_done = "✨",
		separator = " | ",
	}, opts or {})

	local stats = M.get_stats()
	local parts = {}

	if stats.today > 0 then
		table.insert(parts, opts.icon_today .. " Today: " .. stats.today)
	end
	if stats.inbox > 0 then
		table.insert(parts, opts.icon_inbox .. " Inbox: " .. stats.inbox)
	end

	if #parts == 0 then
		return opts.icon_done .. " All Done!"
	end

	return table.concat(parts, opts.separator)
end

return M
