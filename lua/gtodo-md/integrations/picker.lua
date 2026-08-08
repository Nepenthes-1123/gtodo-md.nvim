local M = {}

-- タスクのトグル処理（全ピッカーで共通利用）
-- ファイルパスと行番号を受け取り、その行の [ ] を [x] に（またはその逆）切り替える
function M.toggle_task_file_line(file, lnum)
	if vim.fn.filereadable(file) == 0 then
		return
	end

	-- io_mod 経由で読む。開いているバッファがあればその内容(未保存分を含む)が返るため、
	-- 直後の書き戻しでユーザーの未保存編集を潰さずに済む。
	local io_mod = require("gtodo-md.io")
	local lines = io_mod.read_lines(file)
	local line = lines[lnum]
	if not line then
		return
	end

	-- タスク行の読み書きは task.lua に委ねる。
	--
	-- 以前はここで `utils.is_todo_line`/`is_done_line` (無アンカーの部分文字列検索)で
	-- 判定し、`line:gsub("%[%s%]", "[x]")` で書き換えていた。Lua の gsub は件数を
	-- 指定しなければ**全件置換**なので、本文中にチェックボックス記法を含むタスク
	-- (例: `- [ ] Review checklist template: contains [ ] and [x] placeholders`)を
	-- トグルすると本文まで無警告で書き換わっていた。この経路は io.write_lines で
	-- ディスクへ確定するため、元の本文を戻す手段が実質無い。
	local task_mod = require("gtodo-md.task")
	local task = task_mod.parse(line)
	if not task then
		return
	end

	if task.status == "x" then
		task.status = " "
		task.completed_at = nil
	else
		task.status = "x"
		task.completed_at = os.date("%Y-%m-%d")
	end

	lines[lnum] = task_mod.serialize(task)
	local ok, err = pcall(io_mod.write_lines, file, lines)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.notify("Task toggled!", vim.log.levels.INFO)
end

--------------------------------------------------------------------------------
-- Snacks Picker 連携
--------------------------------------------------------------------------------
function M.snacks(items)
	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker then
		return false
	end

	snacks.picker.pick({
		title = "Gtodo Search",
		items = items,
		-- 独自のハイライトとアイコンを適用するためのフォーマット関数
		format = function(item, _)
			local parts = {}

			-- セクション部分 (例: [Today])
			local section = item.text:match("^(%[.-%])")
			if section then
				table.insert(parts, { section .. " ", "Comment" })
			end

			-- アイコンとコンテンツ
			local rest = item.text:gsub("^(%[.-%])%s*", "")
			local icon_match = rest:match("^(%-[ %[%]x ]+)")
			local content = rest:gsub("^(%-[ %[%]x ]+)%s*", "")

			if icon_match then
				table.insert(parts, { icon_match, "Comment" })
			end

			-- 優先度、プロジェクト、コンテキストのハイライト (簡易版)
			for word in content:gmatch("%S+") do
				local hl = "Normal"
				if word:match("^%([A-Z]%)$") then
					if word == "(A)" then
						hl = "DiagnosticError"
					elseif word == "(B)" then
						hl = "DiagnosticWarn"
					else
						hl = "DiagnosticInfo"
					end
				elseif word:match("^%+") then
					hl = "Type"
				elseif word:match("^@") then
					hl = "Identifier"
				elseif word:match("^due:") then
					hl = "String"
				end
				table.insert(parts, { word .. " ", hl })
			end

			return parts
		end,
		actions = {
			open_task = function(picker, item)
				if item and item.file then
					picker:close()
					require("gtodo-md.ui").open_float(item.file)
					pcall(vim.api.nvim_win_set_cursor, 0, { item.pos[1], 0 })
				end
			end,
			toggle_task = function(picker, item)
				local sel = picker:selected()
				local targets = (sel and #sel > 0) and sel or { item }

				local updated = false
				for _, t in ipairs(targets) do
					if t and t.file then
						M.toggle_task_file_line(t.file, t.pos[1])
						updated = true
					end
				end

				if updated then
					picker:close()
				end
			end,
		},
		win = {
			input = {
				keys = {
					["<CR>"] = { "open_task", desc = "Open Task in Float", mode = { "n", "i" } },
					["<c-x>"] = { "toggle_task", desc = "Toggle Task Done/Undone", mode = { "n", "i" } },
					["x"] = { "toggle_task", desc = "Toggle Task Done/Undone", mode = "n" },
					["　"] = {
						function()
							vim.api.nvim_feedkeys(" ", "n", false)
						end,
						desc = "Convert full-width space to half-width space",
						mode = "i",
					},
				},
			},
			list = {
				keys = {
					["<CR>"] = { "open_task", desc = "Open Task in Float", mode = "n" },
					["x"] = { "toggle_task", desc = "Toggle Task Done/Undone", mode = "n" },
				},
			},
		},
	})
	return true
end

--------------------------------------------------------------------------------
-- Telescope 連携
--------------------------------------------------------------------------------
function M.telescope(items)
	local ok, _ = pcall(require, "telescope")
	if not ok then
		return false
	end

	local t_pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local action_state = require("telescope.actions.state")
	local actions = require("telescope.actions")

	t_pickers
		.new({}, {
			prompt_title = "Gtodo Search",
			finder = finders.new_table({
				results = items,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.text,
						ordinal = entry.text,
						filename = entry.file,
						lnum = entry.pos[1],
						col = entry.pos[2],
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = conf.qflist_previewer({}),
			attach_mappings = function(prompt_bufnr, map)
				local toggle_task = function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local selections = picker:get_multi_selection()
					local targets = (selections and #selections > 0) and selections
						or { action_state.get_selected_entry() }

					local updated = false
					for _, t in ipairs(targets) do
						if t and t.filename then
							M.toggle_task_file_line(t.filename, t.lnum)
							updated = true
						end
					end

					if updated then
						actions.close(prompt_bufnr)
					end
				end

				local open_task = function()
					local selection = action_state.get_selected_entry()
					if selection and selection.filename then
						actions.close(prompt_bufnr)
						require("gtodo-md.ui").open_float(selection.filename)
						pcall(vim.api.nvim_win_set_cursor, 0, { selection.lnum, 0 })
					end
				end

				map("i", "<CR>", open_task)
				map("n", "<CR>", open_task)
				map("i", "<C-x>", toggle_task)
				map("n", "<C-x>", toggle_task)
				map("n", "x", toggle_task)
				map("i", "　", "<Space>")
				return true
			end,
		})
		:find()
	return true
end

--------------------------------------------------------------------------------
-- fzf-lua 連携
--------------------------------------------------------------------------------
function M.fzf_lua(items)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		return false
	end

	-- fzf-lua は ANSI escape sequence で色付け可能
	local function to_ansi(text)
		local section = text:match("^(%[.-%])")
		local rest = text:gsub("^(%[.-%])%s*", "")

		local colored = ""
		if section then
			colored = "\27[90m" .. section .. " \27[0m" -- Gray
		end

		for word in rest:gmatch("%S+") do
			if word:match("^%([A-Z]%)$") then
				if word == "(A)" then
					colored = colored .. "\27[31m" .. word .. " \27[0m" -- Red
				elseif word == "(B)" then
					colored = colored .. "\27[33m" .. word .. " \27[0m" -- Yellow
				else
					colored = colored .. "\27[36m" .. word .. " \27[0m"
				end -- Cyan
			elseif word:match("^%+") then
				colored = colored .. "\27[32m" .. word .. " \27[0m" -- Green
			elseif word:match("^@") then
				colored = colored .. "\27[34m" .. word .. " \27[0m" -- Blue
			elseif word:match("^due:") then
				colored = colored .. "\27[35m" .. word .. " \27[0m" -- Magenta
			else
				colored = colored .. word .. " "
			end
		end
		return colored
	end

	local fzf_items = {}
	for _, item in ipairs(items) do
		local colored = to_ansi(item.text)
		local line_str = string.format("%s:%d:%d:%s", item.file, item.pos[1], item.pos[2], colored)
		table.insert(fzf_items, line_str)
	end

	fzf.fzf_exec(fzf_items, {
		prompt = "Gtodo Search> ",
		previewer = "builtin",
		fzf_opts = {
			["--bind"] = "　:put( )",
		},
		actions = {
			["default"] = function(selected, _)
				if not selected or #selected == 0 then
					return
				end
				local sel = selected[1] -- default action only processes the first item usually, or we can just loop and take the first
				local file, lnum = sel:match("^(.-):(%d+):")
				if file and lnum then
					require("gtodo-md.ui").open_float(file)
					pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), 0 })
				end
			end,
			["ctrl-x"] = function(selected, _)
				if not selected or #selected == 0 then
					return
				end
				for _, sel in ipairs(selected) do
					local file, lnum = sel:match("^(.-):(%d+):")
					if file and lnum then
						M.toggle_task_file_line(file, tonumber(lnum))
					end
				end
			end,
		},
	})
	return true
end

return M
