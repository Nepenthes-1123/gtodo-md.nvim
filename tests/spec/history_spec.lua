-- tests/spec/history_spec.lua
-- Issue #83 回帰テスト: append_to_history が io_mod.read_lines() を使い、
-- バッファ優先の読み込みで未保存内容を失わないことを確認する。

local history = require("gtodo-md.logic.history")

-- ========================================================================
-- ヘルパー
-- ========================================================================

--- 一時ファイルを作成して内容を書き込む
local function make_tmpfile(lines)
	local path = vim.fn.tempname() .. ".md"
	vim.fn.writefile(lines, path)
	return path
end

--- 一時ファイルを読み込んで行リストを返す
local function read_tmpfile(path)
	return vim.fn.readfile(path)
end

-- ダミータスクオブジェクト（task.serialize が扱える最小構成）
local function make_task(content)
	return { status = "x", content = content, indent = "" }
end

-- ========================================================================
-- テスト
-- ========================================================================

describe("history.append_to_history", function()
	describe("ファイルが存在する場合", function()
		it("既存の内容末尾にタスクを追記する", function()
			local path = make_tmpfile({
				"# Done",
				"",
				"## 2025-01",
				"",
				"- [x] 既存タスク",
			})

			history.append_to_history(path, "Done", "2025-01", { make_task("新しいタスク") })

			local result = read_tmpfile(path)
			vim.fn.delete(path)

			local found_existing = false
			local found_new = false
			for _, line in ipairs(result) do
				if line:find("既存タスク") then
					found_existing = true
				end
				if line:find("新しいタスク") then
					found_new = true
				end
			end
			assert.is_true(found_existing, "既存タスクが保持されていること")
			assert.is_true(found_new, "新しいタスクが追記されていること")
		end)

		it("セクションが存在しない場合は新しいセクションを追加する", function()
			local path = make_tmpfile({
				"# Done",
				"",
				"## 2025-01",
				"",
				"- [x] 既存タスク",
			})

			history.append_to_history(path, "Done", "2025-02", { make_task("2月のタスク") })

			local result = read_tmpfile(path)
			vim.fn.delete(path)

			local found_section = false
			local found_task = false
			for _, line in ipairs(result) do
				if line == "## 2025-02" then
					found_section = true
				end
				if line:find("2月のタスク") then
					found_task = true
				end
			end
			assert.is_true(found_section, "新しいセクション見出しが追加されていること")
			assert.is_true(found_task, "タスクが追記されていること")
		end)

		it("既存のセクションに重複して見出しを追加しない", function()
			local path = make_tmpfile({
				"# Done",
				"",
				"## 2025-01",
				"",
				"- [x] 既存タスク",
			})

			history.append_to_history(path, "Done", "2025-01", { make_task("追加タスク") })

			local result = read_tmpfile(path)
			vim.fn.delete(path)

			local section_count = 0
			for _, line in ipairs(result) do
				if line == "## 2025-01" then
					section_count = section_count + 1
				end
			end
			assert.equals(1, section_count, "セクション見出しが重複していないこと")
		end)
	end)

	describe("ファイルが存在しない場合", function()
		it("ヘッダーとセクションを生成してタスクを追記する", function()
			local path = vim.fn.tempname() .. ".md"

			history.append_to_history(path, "Done", "2025-01", { make_task("初回タスク") })

			local result = read_tmpfile(path)
			vim.fn.delete(path)

			assert.is_true(#result > 0, "ファイルが作成されていること")
			assert.equals("# Done", result[1], "ヘッダー行が先頭に存在すること")

			local found_section = false
			local found_task = false
			for _, line in ipairs(result) do
				if line == "## 2025-01" then
					found_section = true
				end
				if line:find("初回タスク") then
					found_task = true
				end
			end
			assert.is_true(found_section, "セクション見出しが存在すること")
			assert.is_true(found_task, "タスクが存在すること")
		end)
	end)

	describe("Issue #83 回帰: io.open ではなく io_mod.read_lines() を使う", function()
		it("バッファが存在しない場合でもディスク上のファイルを正しく読み込む", function()
			local path = make_tmpfile({
				"# Cancelled",
				"",
				"## 2025-03",
				"",
				"- [x] 既存キャンセルタスク",
			})

			history.append_to_history(path, "Cancelled", "2025-03", { make_task("新規キャンセル") })

			local result = read_tmpfile(path)
			vim.fn.delete(path)

			local found_existing = false
			local found_new = false
			for _, line in ipairs(result) do
				if line:find("既存キャンセルタスク") then
					found_existing = true
				end
				if line:find("新規キャンセル") then
					found_new = true
				end
			end
			assert.is_true(found_existing, "既存タスクが失われていないこと（回帰確認）")
			assert.is_true(found_new, "新しいタスクが追記されていること")
		end)
	end)
end)
