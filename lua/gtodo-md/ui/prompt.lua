local M = {}

-- 新規タスクの追加または編集 (ハイブリッド対話メニュー方式)
function M.prompt_task(initial_task, callback)
	local task = initial_task or {}

	local function input(opts, on_confirm)
		local ok, snacks = pcall(require, "snacks")
		if ok and snacks.input then
			local merged_opts = vim.tbl_deep_extend("force", opts, {
				win = {
					relative = "editor",
				},
			})
			snacks.input(merged_opts, on_confirm)
		else
			vim.ui.input(opts, on_confirm)
		end
	end

	-- 既存プロジェクト一覧の取得 (最近更新された順、アーカイブ済みを除く)
	local function get_projects()
		return require("gtodo-md.ui.project").list_active_project_tags()
	end

	local function create_project_file(project_tag)
		require("gtodo-md.ui.project").create_project_file(project_tag)
	end

	-- Step 1: 説明
	input({
		prompt = "Description (required): ",
		default = task.content or "",
	}, function(content)
		if not content or vim.trim(content) == "" then
			if not initial_task then
				vim.notify("Description is required to create a task.", vim.log.levels.ERROR)
				return
			else
				return -- 編集時はキャンセル
			end
		end
		task.content = vim.trim(content)

		-- Step 2: Due Date 手入力 (中央表示の Snacks.input 経由)
		local default_due = task.due or ""
		input({
			prompt = "Due date (e.g. today, tomorrow, +3d, 2026-07-02) [Skip]: ",
			default = default_due,
		}, function(due_input)
			local final_due = nil
			if due_input and vim.trim(due_input) ~= "" then
				due_input = vim.trim(due_input)
				local normalized = require("gtodo-md.utils").parse_due_date(due_input)
				if not normalized then
					vim.notify("Invalid date format. Skipping due date.", vim.log.levels.WARN)
				else
					final_due = normalized
				end
			end
			task.due = final_due

			-- Step 3: Project 選択 (New Project... を常に上部に配置)
			local projects = get_projects()
			local proj_options = {}
			local default_proj_opt = "[Skip]"

			if task.project and task.project ~= "" then
				default_proj_opt = task.project
				table.insert(proj_options, task.project)
			end

			table.insert(proj_options, "[Skip]")
			table.insert(proj_options, "New Project...")

			for _, p in ipairs(projects) do
				if p ~= task.project then
					table.insert(proj_options, p)
				end
			end

			vim.ui.select(proj_options, {
				prompt = "Select Project:",
				default = default_proj_opt,
			}, function(proj_choice)
				if not proj_choice then
					return
				end

				local function proceed_with_project(final_project)
					task.project = final_project

					-- Step 4: Context 選択
					local default_ctx_opt = "[Skip]"
					if task.context and task.context ~= "" then
						default_ctx_opt = task.context
						if not default_ctx_opt:match("^@") then
							default_ctx_opt = "@" .. default_ctx_opt
						end
					end

					local ctx_options = {}
					if default_ctx_opt ~= "[Skip]" then
						table.insert(ctx_options, default_ctx_opt)
					end
					table.insert(ctx_options, "[Skip]")

					for _, c in ipairs({ "@15", "@30", "@60", "@long" }) do
						if c ~= default_ctx_opt then
							table.insert(ctx_options, c)
						end
					end

					vim.ui.select(ctx_options, {
						prompt = "Select Context:",
						default = default_ctx_opt,
						format_item = function(item)
							if item == "[Skip]" then
								return item
							end
							local meaning = ""
							if item == "@15" then
								meaning = " (15 min)"
							elseif item == "@30" then
								meaning = " (30 min)"
							elseif item == "@60" then
								meaning = " (60 min)"
							elseif item == "@long" then
								meaning = " (>60 min)"
							end
							return item .. meaning
						end,
					}, function(ctx_choice)
						if not ctx_choice then
							return
						end
						if ctx_choice == "[Skip]" then
							task.context = nil
						else
							task.context = ctx_choice
						end

						-- 最終決定
						if not task.created then
							task.created = os.date("%Y-%m-%d")
						end
						if not task.status then
							task.status = " "
						end

						callback(task)
					end)
				end

				-- プロジェクト選択判定
				if proj_choice == "New Project..." then
					input({
						prompt = "New Project Name (e.g. site-renewal): ",
						default = "",
					}, function(new_proj)
						if not new_proj or vim.trim(new_proj) == "" then
							proceed_with_project(nil)
						else
							new_proj = vim.trim(new_proj):gsub("^%+", "")
							create_project_file(new_proj)
							proceed_with_project(new_proj)
						end
					end)
				elseif proj_choice == "[Skip]" then
					proceed_with_project(nil)
				else
					proceed_with_project(proj_choice)
				end
			end)
		end)
	end)
end

return M
