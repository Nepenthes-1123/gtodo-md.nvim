-- 壊れた .state.json を書き戻さないことの固定。
--
-- 以前は読めない .state.json を黙って空として扱い、次の書き込み(setup() のたびの
-- last_sections、日次ロールオーバーの last_opened、期日通知の状態)でそのまま上書きして
-- いたため、中身が消え、壊れていたことにも誰も気づけなかった。CLI/TUI の移植で
-- 見つかり、そのロードマップに Lua 版の不具合として記録されていたもの。

local state = require("gtodo-md.state")
local config = require("gtodo-md.config")

describe("壊れた .state.json", function()
	local data_dir, state_path, notes, saved_notify

	local function write_raw(content)
		local f = assert(io.open(state_path, "wb"))
		f:write(content)
		f:close()
	end

	local function read_raw()
		local f = assert(io.open(state_path, "rb"))
		local content = f:read("*a")
		f:close()
		return content
	end

	local function errors()
		return vim.tbl_filter(function(n)
			return n.level == vim.log.levels.ERROR
		end, notes)
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		vim.fn.mkdir(data_dir .. "/projects", "p")
		state_path = data_dir .. "/.state.json"
		notes = {}
		saved_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notes, { msg = tostring(msg), level = level })
		end
		config.setup({ data_dir = data_dir })
		notes = {}
	end)

	after_each(function()
		vim.notify = saved_notify
		config.setup({ data_dir = data_dir })
		vim.fn.delete(data_dir, "rf")
	end)

	for _, content in ipairs({ "{broken", "[1, 2]", "1", '"x"', "\255\254" }) do
		it("書き戻さずにエラーを通知する: " .. vim.inspect(content), function()
			write_raw(content)

			state.write_last_opened("2026-11-11")

			assert.are.equal(content, read_raw())
			assert.are.equal(1, #errors(), vim.inspect(notes))
			assert.is_truthy(errors()[1].msg:find(state_path, 1, true), errors()[1].msg)
		end)
	end

	-- setup() のたび・期日通知のたびに書きに来るため、毎回通知すると止まらない。
	it("同じファイルについての通知は1度だけにする", function()
		write_raw("{broken")

		config.setup({ data_dir = data_dir })
		state.write_last_opened("2026-11-11")
		state.write_notify_state(1, "x")

		assert.are.equal("{broken", read_raw())
		assert.are.equal(1, #errors(), vim.inspect(notes))
	end)

	it("読むときは空として扱い、処理を止めない", function()
		write_raw("{broken")

		assert.is_nil(state.read_last_opened())
		assert.is_nil(state.read_last_sections())
		assert.are.same({ 0, "" }, { state.read_notify_state() })
	end)

	it("直したら、また書ける", function()
		write_raw("{broken")
		state.write_last_opened("2026-11-10")

		write_raw("{}")
		state.write_last_opened("2026-11-11")

		assert.are.equal("2026-11-11", vim.json.decode(read_raw()).last_opened)
	end)

	-- 空のファイルと、空のテーブルを vim.json.encode した "[]" は壊れていない(CLI も同じ扱い)。
	for _, content in ipairs({ "", "  \n", "[]" }) do
		it("空の状態として書ける: " .. vim.inspect(content), function()
			write_raw(content)

			state.write_last_opened("2026-11-11")

			assert.are.equal("2026-11-11", vim.json.decode(read_raw()).last_opened)
			assert.are.same({}, errors())
		end)
	end

	it("知らないキーは書き戻しても残る", function()
		write_raw('{"future_key":{"a":1},"last_opened":"2026-01-01"}')

		state.write_last_opened("2026-11-11")

		local decoded = vim.json.decode(read_raw())
		assert.are.same({ a = 1 }, decoded.future_key)
		assert.are.equal("2026-11-11", decoded.last_opened)
	end)
end)
