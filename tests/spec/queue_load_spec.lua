-- #93 回帰テスト: Queue が未ロードのファイルをバッファ化する際、
-- BufRead 系のautocmdを誤って発火させないことを確認する。

local queue_mod = require("gtodo-md.ui.queue")

describe("ui.queue._load_buf_quietly", function()
	local path

	before_each(function()
		path = vim.fn.tempname() .. "_queue_load.md"
		vim.fn.writefile({ "# Todo", "" }, path)
	end)

	after_each(function()
		vim.fn.delete(path)
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == path then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
	end)

	it("未ロードのファイルを読み込んでも BufRead 系autocmdを発火させない", function()
		local group = vim.api.nvim_create_augroup("TestQueueLoadQuietly", { clear = true })
		local fired = {}
		vim.api.nvim_create_autocmd({ "BufRead", "BufReadPre", "BufReadPost", "BufEnter" }, {
			group = group,
			pattern = "*_queue_load.md",
			callback = function(args)
				table.insert(fired, args.event)
			end,
		})

		local buf = queue_mod._load_buf_quietly(path)

		assert.is_true(vim.api.nvim_buf_is_loaded(buf))
		assert.are.same({}, fired, "BufRead系autocmdが発火した: " .. vim.inspect(fired))

		vim.api.nvim_del_augroup_by_id(group)
	end)

	it("正しくファイル内容を読み込む", function()
		local buf = queue_mod._load_buf_quietly(path)
		assert.are.same({ "# Todo", "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)

	it("既にロード済みのバッファはそのまま返す(eventignoreを触らない)", function()
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		local existing_buf = vim.api.nvim_get_current_buf()

		local prev_ei = vim.o.eventignore
		local buf = queue_mod._load_buf_quietly(path)

		assert.are.same(existing_buf, buf)
		assert.are.same(prev_ei, vim.o.eventignore)
	end)
end)
