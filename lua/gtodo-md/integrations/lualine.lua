local M = {}

-- Lualine用のコンポーネント設定を生成する
function M.component(opts)
	opts = vim.tbl_deep_extend("force", {
		icon_today = "󰃭",
		icon_inbox = "󰚦",
		icon_done = "󰄴",
		separator = " | ",
		color = { fg = "#a6e3a1", gui = "bold" }, -- Catppuccin Green
	}, opts or {})

	return {
		function()
			local ok, api = pcall(require, "gtodo-md.api")
			if not ok then
				return ""
			end

			local stats = api.get_stats()
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
		end,
		cond = function()
			-- ウィンドウ幅が狭い時は非表示にする
			return vim.o.columns > 80
		end,
		color = opts.color,
	}
end

return M
