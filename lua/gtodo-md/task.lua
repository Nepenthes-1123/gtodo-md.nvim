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

-- タグ抽出のパターン。**タスク行の文法の正本はここだけ**であり、他のモジュールが
-- 独自に正規表現を組み立ててはならない(そうして生まれた不具合は CLAUDE.md を参照)。
--
-- 値の文字種は自動生成される16進数を想定しているが、パース自体は
-- (手編集等で非16進の値が入っていても)非空白文字列であれば受け付ける。
-- ここを16進限定にすると、値が不正な場合に id: だけでなく後続の
-- 全タグの抽出まで連鎖的に失敗する(各パターンが行末 $ に固定されているため)。
local TAG_PATTERNS = {
	{ key = "id", pat = "\\<id:\\S\\+\\s*$" },
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

-- `key:value` 形式のタグ名の集合。`+project`/`@context` は形が違うため含まない。
local KEY_VALUE_TAGS = {}
for _, p in ipairs(TAG_PATTERNS) do
	if p.key ~= "project" and p.key ~= "context" then
		KEY_VALUE_TAGS[p.key] = true
	end
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

	local patterns = TAG_PATTERNS

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

-- 行の中の `key:value` 形式タグの位置を返す。
-- 戻り値: { { key = "id", start_col = <0-indexed>, end_col = <exclusive> }, ... }
-- タスク行でなければ空リストを返す。
--
-- **表示側(conceal/ハイライト)が自前で正規表現を組まずに済むようにするための関数である。**
-- タグの文法を各所で再実装すると、行末アンカーの前提が崩れて黙って失敗する・無差別な
-- マッチで本文を巻き込む、といった不具合を生む(実際に3件生まれた。CLAUDE.md 参照)。
-- ここは `M.parse` と同じ `TAG_PATTERNS` を同じ剥がし順で適用するため、
-- パース結果と位置が食い違うことはない。
--
-- 範囲は**直前の空白を含み、後ろの空白は含まない**。
-- 各パターンは末尾の `\s*` までマッチするが、それをそのまま範囲にすると隣り合う
-- タグと1バイト重なって conceal の extmark が重複する。前寄せに統一すると範囲が
-- 隙間なく並ぶうえ、途中のタグだけを隠しても二重空白にならず、全部隠したときに
-- 末尾へ余分な空白も残らない。
-- `+project`/`@context` は `key:value` 形式ではないので含まない。
function M.tag_ranges(line)
	local _, status, rest = line:match("^(%s*)%-%s*%[([ xX])%]%s*(.*)$")
	if not status then
		return {}
	end

	-- rest は line の末尾側の部分文字列なので、その開始バイト位置は差分で求まる。
	local rest_offset = #line - #rest
	-- parse と同じく、行頭のタグも拾えるよう先頭に番兵の空白を足す。
	local text = " " .. rest

	local ranges = {}
	local matched_any = true
	while matched_any do
		matched_any = false
		for _, p in ipairs(TAG_PATTERNS) do
			local start_idx = vim.fn.match(text, p.pat)
			if start_idx ~= -1 then
				local end_idx = vim.fn.matchend(text, p.pat)
				if KEY_VALUE_TAGS[p.key] then
					-- 直前の空白まで前へ広げる
					local s = start_idx
					while s > 0 and text:sub(s, s):match("%s") do
						s = s - 1
					end
					-- パターンが飲み込んだ末尾の空白を戻す
					local e = end_idx
					while e > start_idx and text:sub(e, e):match("%s") do
						e = e - 1
					end
					-- 先頭に足した番兵の空白1バイト分を差し引いて元の行の座標へ戻す。
					table.insert(ranges, {
						key = p.key,
						start_col = rest_offset + s - 1,
						end_col = rest_offset + e - 1,
					})
				end
				-- 末尾から剥がしていくので、既に記録した位置がずれることはない。
				text = text:sub(1, start_idx)
				matched_any = true
				break
			end
		end
	end

	return ranges
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
