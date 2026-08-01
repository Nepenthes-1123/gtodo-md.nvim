local M = {}
local uv = vim.uv or vim.loop

-- タスクの一意なID(6桁16進数)を発行する。
-- vim.loop.hrtime()(プロセス起動からのナノ秒単位の単調増加クロック)と
-- プロセスID を組み合わせることで、math.random の明示的なシード管理を
-- 必要とせずに複数インスタンス間でも衝突しにくいIDを得る。
-- 万一衝突しても io.lua の write_todo_file 側で検知・再発行されるため、
-- ここでは暗号学的な一意性までは求めない。
function M._generate_id()
	local hr = uv.hrtime()
	local pid = vim.fn.getpid()
	return string.format("%06x", (hr + pid) % 0x1000000)
end

-- タスク行をパースしてテーブルにする
-- タスクでない行は nil を返す
function M.parse(line)
	local indent, status, rest = line:match("^(%s*)%-%s*%[([ xX])%]%s*(.*)$")
	if not status then
		return nil
	end
	-- 大文字Xを小文字に正規化
	status = status:lower()

	local task = {
		indent = indent,
		status = status, -- " " (未完了) or "x" (完了)
		original_line = line,
	}

	local text = rest

	local patterns = {
		{ key = "id", pat = "\\<id:[0-9a-f]\\+\\s*$" },
		{ key = "completed_at", pat = "\\<completed_at:\\d\\{4}-\\d\\{2}-\\d\\{2}\\s*$" },
		{ key = "done", pat = "\\<done:\\d\\{4}-\\d\\{2}-\\d\\{2}\\s*$" },
		{ key = "cancelled", pat = "\\<cancelled:\\d\\{4}-\\d\\{2}-\\d\\{2}\\s*$" },
		{ key = "from", pat = "\\<from:\\w\\+\\s*$" },
		{ key = "due", pat = "\\<due:[a-zA-Z0-9_/%+-]\\+\\s*$" },
		{ key = "created", pat = "\\<created:\\d\\{4}-\\d\\{2}-\\d\\{2}\\s*$" },
		{ key = "context", pat = "\\s\\+@[a-zA-Z0-9_/.-]\\+\\s*$" },
		{ key = "project", pat = "\\s\\++[a-zA-Z0-9_/.-]\\+\\s*$" },
		{ key = "wait", pat = "\\<wait:[^[:space:]　。、.,()（）]\\+\\s*$" },
	}

	-- 安全に行頭のタグも抽出できるように先頭にスペースを付与しておく
	text = " " .. text

	local matched_any = true
	while matched_any do
		matched_any = false
		for _, p in ipairs(patterns) do
			local start_idx = vim.fn.match(text, p.pat)
			if start_idx ~= -1 then
				local end_idx = vim.fn.matchend(text, p.pat)
				local match_text = vim.trim(text:sub(start_idx + 1, end_idx))
				text = text:sub(1, start_idx)

				if p.key == "project" then
					task[p.key] = match_text:sub(2)
				elseif p.key == "context" then
					task[p.key] = match_text
				elseif p.key == "due" then
					local raw_due = match_text:sub(5)
					local normalized = require("gtodo-md.utils").parse_due_date(raw_due)
					task[p.key] = normalized or raw_due
				else
					local colon_idx = match_text:find(":")
					if colon_idx then
						task[p.key] = match_text:sub(colon_idx + 1)
					end
				end

				matched_any = true
				break -- 変更後、文字列末尾が変化したため最初から再チェック
			end
		end
	end

	text = vim.trim(text)

	-- 優先度の抽出: 行頭 (A) 形式
	-- 後ろスペース必須で本文のタイプミスと区別する（P0-3 の位置的制約と同じ設計方針）
	-- (A) タスク   → priority="A", content="タスク"
	-- (WIP) タスク → priority=nil,  content="(WIP) タスク" (複数文字は除外)
	-- (A)タスク    → priority=nil,  content="(A)タスク"   (後ろスペースなし → 除外)
	local cleaned = vim.trim(text:gsub("%s+", " "))
	local pri, after_pri = cleaned:match("^%(([A-Z])%)%s+(.*)")
	if pri then
		task.priority = pri
		task.content = vim.trim(after_pri)
	else
		task.content = cleaned
	end

	return task
end

-- タスクのテーブルから文字列表現を生成する
function M.serialize(task)
	local parts = {}
	-- priority が存在する場合は content 先頭に "(A) " 形式で付与して書き戻す
	local priority_prefix = (task.priority and task.priority ~= "") and ("(" .. task.priority .. ") ") or ""
	table.insert(
		parts,
		string.format("%s- [%s] %s%s", task.indent or "", task.status or " ", priority_prefix, task.content or "")
	)

	if task.project and task.project ~= "" then
		table.insert(parts, "+" .. task.project)
	end

	if task.context and task.context ~= "" then
		local ctx = task.context
		if not ctx:match("^@") then
			ctx = "@" .. ctx
		end
		table.insert(parts, ctx)
	end

	if task.due and task.due ~= "" then
		table.insert(parts, "due:" .. task.due)
	end

	if task.created and task.created ~= "" then
		table.insert(parts, "created:" .. task.created)
	end

	if task.wait and task.wait ~= "" then
		table.insert(parts, "wait:" .. task.wait)
	end

	if task.completed_at and task.completed_at ~= "" then
		table.insert(parts, "completed_at:" .. task.completed_at)
	end

	if task.done and task.done ~= "" then
		table.insert(parts, "done:" .. task.done)
	end

	if task.cancelled and task.cancelled ~= "" then
		table.insert(parts, "cancelled:" .. task.cancelled)
	end

	if task.from and task.from ~= "" then
		table.insert(parts, "from:" .. task.from)
	end

	-- 一意なIDを末尾に付与する。未発行の場合はここで新規発行し、
	-- 渡された task テーブルにも書き戻す(以降の呼び出しで再発行されないように)。
	if not task.id or task.id == "" then
		task.id = M._generate_id()
	end
	table.insert(parts, "id:" .. task.id)

	return table.concat(parts, " ")
end
return M
