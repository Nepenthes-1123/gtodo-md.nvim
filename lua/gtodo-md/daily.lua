local M = {}
local config = require("gtodo-md.config")
local logic_mod = require("gtodo-md.logic")

-- 自動処理のキャッシュ用変数
local last_processed_mtimes = {
	inbox = 0,
	todo = 0,
}
local last_processed_date = ""

-- キャッシュ取得用アクセサ
function M.get_cache()
	return last_processed_mtimes, last_processed_date
end

-- キャッシュ更新用アクセサ
function M.update_cache(inbox_mtime, todo_mtime)
	last_processed_mtimes.inbox = inbox_mtime
	last_processed_mtimes.todo = todo_mtime
	last_processed_date = os.date("%Y-%m-%d")
end

-- 日付変更チェックと自動タスク整理
function M.check_daily_rollover()
	local today = os.date("%Y-%m-%d")
	if last_processed_date ~= "" and today == last_processed_date then
		return
	end

	local last_opened = require("gtodo-md.utils").read_last_opened()
	if last_opened ~= today then
		local data_dir = config.get("data_dir")
		local inbox_path = data_dir .. "/inbox.md"
		local todo_path = data_dir .. "/todo.md"
		local done_path = data_dir .. "/done.md"

		local todo_changed = logic_mod.move_completed_tasks(inbox_path, todo_path, done_path)
		if logic_mod.check_dues(inbox_path, todo_path) then
			todo_changed = true
		end
		if todo_changed then
			logic_mod.sort_todo_file(todo_path)
		end
		require("gtodo-md.utils").write_last_opened(today)

		last_processed_mtimes.inbox = vim.fn.getftime(inbox_path)
		last_processed_mtimes.todo = vim.fn.getftime(todo_path)

		local utils = require("gtodo-md.utils")
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
				local bufname = vim.api.nvim_buf_get_name(buf)
				if utils.is_gtodo_file(bufname) then
					vim.api.nvim_buf_call(buf, function()
						vim.cmd("checktime")
					end)
				end
			end
		end
	end

	last_processed_date = today
end

return M
