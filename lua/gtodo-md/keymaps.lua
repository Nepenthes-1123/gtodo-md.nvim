-- gtodo-md のキーマップ定義。
-- グローバルキーマップ (setup 時に一度だけ) と、gtodo バッファへ張るバッファローカル
-- キーマップ (handle_buf_enter から毎回) の2種類を持つ。
-- いずれも config.keymap_prefix を前置する。
local M = {}

local config = require("gtodo-md.config")
local ui_mod = require("gtodo-md.ui")
local editor_mod = require("gtodo-md.editor")

-- グローバルキーマップの設定
function M.setup_global()
	local prefix = config.get("keymap_prefix")

	-- 表示系
	vim.keymap.set("n", prefix .. "t", function()
		ui_mod.open_todo_float()
	end, { desc = "Toggle Todo float" })
	vim.keymap.set("n", prefix .. "i", function()
		ui_mod.open_inbox_float()
	end, { desc = "Toggle Inbox float" })

	-- 表示系 (履歴)
	vim.keymap.set("n", prefix .. "hd", function()
		ui_mod.open_done_float()
	end, { desc = "Toggle Done float" })
	vim.keymap.set("n", prefix .. "hc", function()
		ui_mod.open_cancelled_float()
	end, { desc = "Toggle Cancelled float" })

	-- 検索
	vim.keymap.set("n", prefix .. "/", function()
		ui_mod.search_tasks()
	end, { desc = "Search tasks" })

	-- 追加・編集系 (適応的)
	vim.keymap.set("n", prefix .. "a", function()
		-- 循環参照を避けるため呼び出し時点で遅延requireする
		require("gtodo-md").add_or_edit_task()
	end, { desc = "Add or edit task" })

	-- Queue ビュー
	vim.keymap.set("n", prefix .. "q", function()
		ui_mod.open_queue()
	end, { desc = "Open Queue view" })
end

-- バッファローカルなキーマップを設定する
function M.setup_buffer(bufnr)
	local prefix = config.get("keymap_prefix")
	local function map(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
	end

	-- 移動系
	map("n", prefix .. "d", function()
		editor_mod.move_current_task_to(config.sections.TODAY)
	end, "Move task to " .. config.sections.TODAY)
	map("n", prefix .. "n", function()
		editor_mod.move_current_task_to(config.sections.NEXT)
	end, "Move task to " .. config.sections.NEXT)
	-- Waiting への移動時に待ち先(wait:)も対話的に設定する。既に Waiting に
	-- いるタスクへ実行した場合はセクションを動かさず wait: だけを更新する。
	map("n", prefix .. "w", function()
		editor_mod.move_current_task_to(config.sections.WAITING)
	end, "Move task to " .. config.sections.WAITING .. " (set wait:)")
	map("n", prefix .. "s", function()
		editor_mod.move_current_task_to(config.sections.SOMEDAY)
	end, "Move task to " .. config.sections.SOMEDAY)

	map("n", prefix .. "x", function()
		editor_mod.toggle_complete()
	end, "Toggle task completion")
	map("n", prefix .. "c", function()
		editor_mod.cancel_current_task()
	end, "Cancel task")

	-- タスク分割・プロジェクト化 (Issue #22)
	map("n", prefix .. "p", function()
		editor_mod.split_current_task()
	end, "Split / Promote task")

	-- ジャンプ系
	map("n", prefix .. "jp", function()
		ui_mod.jump_to_project()
	end, "Jump to project file")

	-- 機能系
	map("n", prefix .. "o", function()
		require("gtodo-md").sort_and_check_dues()
	end, "Sort and check due dates")
end

return M
