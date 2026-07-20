local M = {}
local config = require("gtodo-md.config")
local float_ui = require("gtodo-md.ui.float")

-- AND絞り込み検索
function M.search_tasks()
	local data_dir = config.get("data_dir")
	local files = {
		data_dir .. "/inbox.md",
		data_dir .. "/todo.md",
		data_dir .. "/done.md",
	}

	local task_mod = require("gtodo-md.task")
	local items = {}

	for _, filepath in ipairs(files) do
		if vim.fn.filereadable(filepath) == 1 then
			local lines = {}
			local f = io.open(filepath, "r")
			if f then
				for line in f:lines() do
					table.insert(lines, line)
				end
				f:close()
			end

			for lnum, line in ipairs(lines) do
				local task = task_mod.parse(line)
				if task then
					local fname = vim.fn.fnamemodify(filepath, ":t:r")
					local _, _, clean_line = line:match("^(%s*)%-%s*%[([ xX])%]%s*(.*)$")
					clean_line = clean_line or line
					local display_text = string.format("[%s] %s", fname:upper(), clean_line)
					table.insert(items, {
						text = display_text,
						original_line = line,
						file = filepath,
						pos = { lnum, 1 },
					})
				end
			end
		end
	end

	local picker_opt = config.get("picker")

	local pickers = {
		snacks = function(picker_items)
			local ok, p = pcall(require, "gtodo-md.integrations.picker")
			return ok and p.snacks(picker_items)
		end,
		telescope = function(picker_items)
			local ok, p = pcall(require, "gtodo-md.integrations.picker")
			return ok and p.telescope(picker_items)
		end,
		["fzf-lua"] = function(picker_items)
			local ok, p = pcall(require, "gtodo-md.integrations.picker")
			return ok and p.fzf_lua(picker_items)
		end,
	}

	local launched = false
	if picker_opt == "auto" then
		launched = pickers.snacks(items) or pickers.telescope(items) or pickers["fzf-lua"](items)
	elseif pickers[picker_opt] then
		launched = pickers[picker_opt](items)
	end

	if launched then
		return
	end

	-- Snacks がない場合は従来の vim.ui.input + quickfix 検索
	vim.ui.input({
		prompt = "Search filter (e.g. +project @15 [ ]): ",
		default = "",
	}, function(query)
		if not query then
			return
		end
		query = vim.trim(query)
		query = query:gsub("　", " ")

		local target_project = query:match("%+([%w%-_/%.]+)")
		local target_context = query:match("(@[%w%-_/%.]+)")
		local target_status = nil
		if query:match("%[%s*%]") then
			target_status = " "
		elseif query:match("%[x%]") then
			target_status = "x"
		end

		local qf_list = {}
		for _, item in ipairs(items) do
			local task = task_mod.parse(item.original_line)
			if task then
				local match = true
				if target_project and task.project ~= target_project then
					match = false
				end
				if target_context then
					local tc = target_context
					local tc_clean = tc:match("^@") and tc or ("@" .. tc)
					local task_ctx = task.context
					local task_ctx_clean = task_ctx and (task_ctx:match("^@") and task_ctx or ("@" .. task_ctx))
					if task_ctx_clean ~= tc_clean then
						match = false
					end
				end
				if target_status and task.status ~= target_status then
					match = false
				end

				if match then
					table.insert(qf_list, {
						filename = item.file,
						lnum = item.pos[1],
						text = item.text,
					})
				end
			end
		end

		if #qf_list == 0 then
			vim.notify("No matching tasks found.", vim.log.levels.INFO)
			return
		end

		vim.ui.select(qf_list, {
			prompt = string.format("Gtodo Search: %s", query),
			format_item = function(item)
				local fname = vim.fn.fnamemodify(item.filename, ":t")
				return string.format("%s:%d | %s", fname, item.lnum, item.text)
			end,
		}, function(choice)
			if not choice then
				return
			end
			float_ui.open_float(choice.filename)
			pcall(vim.api.nvim_win_set_cursor, 0, { choice.lnum, 0 })
		end)
	end)
end

return M
