local M = {}

function M.check()
	vim.health.start("gtodo-md")

	-- 1. 依存プラグインのチェック
	-- plenary
	local has_plenary, _ = pcall(require, "plenary")
	if has_plenary then
		vim.health.ok("plenary.nvim is installed")
	else
		vim.health.error("plenary.nvim is missing", {
			"Install 'nvim-lua/plenary.nvim' which is required for tasks searching.",
		})
	end

	-- snacks
	local has_snacks, _ = pcall(require, "snacks")
	if has_snacks then
		vim.health.ok("snacks.nvim is installed")
	else
		vim.health.warn("snacks.nvim is missing", {
			"Optional: Install 'folke/snacks.nvim' for nicer input and picker UI.",
		})
	end

	-- ピッカー (Telescope, fzf-lua)
	local pickers = {}
	if pcall(require, "telescope") then
		table.insert(pickers, "telescope")
	end
	if pcall(require, "fzf-lua") then
		table.insert(pickers, "fzf-lua")
	end
	if has_snacks then
		table.insert(pickers, "snacks.picker")
	end

	if #pickers > 0 then
		vim.health.ok("Available pickers: " .. table.concat(pickers, ", "))
	else
		vim.health.warn(
			"No advanced fuzzy pickers installed. Falling back to builtin quickfix list.",
			{
				"Install 'nvim-telescope/telescope.nvim' or 'ibhagwan/fzf-lua' for enhanced task search UI.",
			}
		)
	end

	-- 2. 設定 & データディレクトリのチェック
	local config_ok, config = pcall(require, "gtodo-md.config")
	if not config_ok or not config.options or not config.options.data_dir then
		vim.health.warn("Plugin setup has not been run yet.", {
			"Add `require('gtodo-md').setup({})` to your Neovim configurations.",
		})
		return
	end

	local data_dir = config.options.data_dir
	vim.health.ok("data_dir is set to: " .. data_dir)

	if vim.fn.isdirectory(data_dir) == 1 then
		vim.health.ok("data_dir directory exists")
	else
		vim.health.error("data_dir directory does not exist or is not readable: " .. data_dir, {
			"Verify the path in config or let the plugin create it during setup.",
		})
	end

	-- 必須ファイルのチェック
	local files = { "inbox.md", "todo.md", "done.md", "cancelled.md" }
	local missing_files = {}
	for _, fname in ipairs(files) do
		local fpath = data_dir .. "/" .. fname
		if vim.fn.filereadable(fpath) == 0 then
			table.insert(missing_files, fname)
		end
	end

	if #missing_files == 0 then
		vim.health.ok("All core Markdown files exist and are readable")
	else
		vim.health.warn("Some core files are missing: " .. table.concat(missing_files, ", "), {
			"They will be created automatically when you first open inbox.md or todo.md.",
		})
	end

	-- 3. 状態ファイルのチェック
	local state_file = data_dir .. "/.state.json"
	if vim.fn.filereadable(state_file) == 1 then
		local f = io.open(state_file, "r")
		if f then
			local content = f:read("*all")
			f:close()
			local ok, _ = pcall(vim.json.decode, content)
			if ok then
				vim.health.ok(".state.json is valid")
			else
				vim.health.error(".state.json is corrupted", {
					"Delete the corrupted file at: " .. state_file .. ". The plugin will regenerate it.",
				})
			end
		end
	else
		vim.health.ok(".state.json does not exist yet (it will be created automatically)")
	end
end

return M
