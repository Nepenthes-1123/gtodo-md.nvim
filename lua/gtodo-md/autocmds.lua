-- gtodo-md が登録する autocmd 群。
-- 保存時バリデーションの結線、autoread、バッファ再読み込みのオーケストレーションなど、
-- 横断的な振る舞いはここに集約されている。
-- 判定ルール自体は validate.lua の純関数が持ち、ここでの各コールバックは
-- 「対象バッファか判定 → バッファ行を取得 → validate.lua に問い合わせ →
-- エラーメッセージを組み立てて error(msg, 0)」に徹する。
local M = {}

local utils_mod = require("gtodo-md.utils")
local validate_mod = require("gtodo-md.validate")
local timer_mod = require("gtodo-md.timer")

function M.setup()
	local group = vim.api.nvim_create_augroup("GtodoMd", { clear = true })

	-- この setup 実行インスタンスに完全にカプセル化されたキャッシュテーブル
	-- augroup のクリア (clear = true) と連動して再初期化されるため、古い Autocmd との不整合は起きない
	local original_created_dates = {}
	local original_history_sections = {}

	-- todo.md 保存時のバリデーション
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = group,
		pattern = { "todo.md" },
		callback = function(args)
			-- #91: patternはファイル名の末尾一致のみで、data_dir外の同名ファイルにも
			-- マッチしてしまう。is_gtodo_fileでパスベースに対象外を除外する。
			if not utils_mod.is_gtodo_file(vim.api.nvim_buf_get_name(args.buf)) then
				return
			end
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local missing = validate_mod.missing_todo_sections(lines)

			if #missing > 0 then
				local msg = "[gtodo-md] 必須セクションが不足しているため保存を中断しました ("
					.. table.concat(missing, ", ")
					.. ") ※スタックトレースは仕様です"
				-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
				-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
				error(msg, 0)
			end
		end,
	})

	-- done.md, cancelled.md ロード/表示時に既存の年月セクション見出しをキャッシュする
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = group,
		pattern = { "done.md", "cancelled.md" },
		callback = function(args)
			if original_history_sections[tostring(args.buf)] then
				return
			end

			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			original_history_sections[tostring(args.buf)] = validate_mod.collect_history_sections(lines)
		end,
	})

	-- inbox.md, done.md, cancelled.md 保存時のヘッダー保護
	local history_patterns = {
		["inbox.md"] = "# Inbox",
		["done.md"] = "# Done",
		["cancelled.md"] = "# Cancelled",
	}

	for fname, expected_header in pairs(history_patterns) do
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = group,
			pattern = fname,
			callback = function(args)
				-- #91: data_dir外の同名ファイルを除外する
				if not utils_mod.is_gtodo_file(vim.api.nvim_buf_get_name(args.buf)) then
					return
				end
				local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)

				if not validate_mod.has_required_header(lines, expected_header) then
					local msg = string.format(
						"[gtodo-md] 必須ヘッダー (%s) が削除されたため保存を中断しました ※スタックトレースは仕様です",
						expected_header
					)
					-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
					-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
					error(msg, 0)
				end

				-- 年月セクションの削除保護 (done.md と cancelled.md のみ)
				if fname == "done.md" or fname == "cancelled.md" then
					local original_secs = original_history_sections[tostring(args.buf)] or {}
					local missing_secs = validate_mod.missing_history_sections(lines, original_secs)

					if #missing_secs > 0 then
						local msg = string.format(
							"[gtodo-md] 既存の履歴セクション (%s) が削除されたため保存を中断しました ※スタックトレースは仕様です",
							table.concat(missing_secs, ", ")
						)
						-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
						-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
						error(msg, 0)
					end
				end
			end,
		})
	end

	-- projects/*.md ロード/表示時に created の値とフロントマターをキャッシュする
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = group,
		pattern = { "*/projects/*.md" },
		callback = function(args)
			if original_created_dates[tostring(args.buf)] then
				return
			end

			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local created = validate_mod.extract_frontmatter_created(lines)
			if created then
				original_created_dates[tostring(args.buf)] = created
			end
		end,
	})

	-- projects/*.md 保存時のフロントマター保護
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = group,
		pattern = { "*/projects/*.md" },
		callback = function(args)
			-- #91: data_dir外の同名パスを除外する
			if not utils_mod.is_gtodo_file(vim.api.nvim_buf_get_name(args.buf)) then
				return
			end
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local filepath = args.match
			local proj_name = vim.fn.fnamemodify(filepath, ":t:r")

			-- フロントマター検証
			local original_created = original_created_dates[tostring(args.buf)]
			local errors = validate_mod.validate_project_frontmatter(lines, proj_name, original_created)

			if #errors > 0 then
				local msg = "[gtodo-md] フロントマターが不正なため保存を中断しました ("
					.. table.concat(errors, " / ")
					.. ") ※スタックトレースは仕様です"
				-- BufWritePreの中で標準の保存処理を中断させるには例外エラーを投げる必要がある。
				-- 見栄えを良くするため、第2引数に0を渡してLuaのスタックトレースを非表示にしている。
				error(msg, 0)
			end
		end,
	})

	-- バッファが完全にメモリから消去された時のみキャッシュメモリを解放
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		pattern = "*",
		callback = function(args)
			local bufnr = args.buf
			-- バッファがまだ有効またはロード済みの場合は、誤検知なのでクリアをスキップする！
			if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
				return
			end

			original_history_sections[tostring(bufnr)] = nil
			original_created_dates[tostring(bufnr)] = nil
		end,
	})

	-- gtodo-md 対象バッファへ autoread を設定し、永続 undo を無効化する。
	--
	-- #125: undofile を落とすのはバッファ生成時が本筋。checktime は外部変更を
	-- 検知してリロードした直後に u_write_undo() を呼ぶため('undofile' 有効時)、
	-- 同じファイルを開いた複数インスタンスが同一の undo ファイルを
	-- 「削除 → O_EXCL で作成」で奪い合い、負けた側が E828 になる。
	-- さらに undo 情報が空のインスタンスがリロードを踏むと、既存の undo ファイルを
	-- 黙って削除するため、E828 が出ないケースでも永続 undo は成立していない。
	-- write_lines が :w を介さずディスクを書き換える設計上、これらのファイルの
	-- 永続 undo は元から意味を持たない(バッファ内の undo は従来どおり効く)。
	-- daily.reload_managed_bufs 側にも同じ設定があるが、あちらは保険。
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = group,
		pattern = "*",
		callback = function(args)
			if vim.api.nvim_buf_is_valid(args.buf) then
				local bufname = vim.api.nvim_buf_get_name(args.buf)
				if utils_mod.is_gtodo_file(bufname) then
					vim.bo[args.buf].autoread = true
					vim.bo[args.buf].undofile = false
				end
			end
		end,
	})

	-- #125: バッファとディスクが一致していると言える瞬間を io.lua のスタンプ表へ記録する。
	-- 記録した値は write_lines 直前の照合に使われ、他インスタンス(やユーザーの :w)が
	-- 割り込んだ内容を全行置換で潰すのを防ぐ。
	-- **BufEnter を契機に含めてはならない** — バッファがディスクと一致している保証が無く、
	-- 古いバッファに新しいディスクの stat を刻印すると照合が素通りしてしまう。
	--
	-- FileChangedShellPost が必要な理由: autoread/checktime によるリロードは
	-- BufReadPost を発火させない(highlight のアタッチが同イベントを別途購読しているのも
	-- 同じ理由)。ここを取りこぼすと、リロードでバッファが最新になったのにスタンプが
	-- 古いまま残り、以降そのパスへの書き込みが恒久的に拒否される。
	--
	-- data_dir 外のパスでも、既に追跡中(＝プラグインが読み書きした)ものは更新する。
	-- 追跡していないパスまで記録すると表が無制限に育つため入口を分けている。
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, {
		group = group,
		pattern = "*",
		callback = function(args)
			if vim.api.nvim_buf_is_valid(args.buf) then
				local bufname = vim.api.nvim_buf_get_name(args.buf)
				local io_mod = require("gtodo-md.io")
				if utils_mod.is_gtodo_file(bufname) then
					io_mod.record_stamp(bufname)
				else
					io_mod.refresh_stamp_if_tracked(bufname)
				end
			end
		end,
	})

	-- inbox.md, todo.md 用
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = { "inbox.md", "todo.md" },
		callback = function(args)
			vim.schedule(function()
				-- 循環参照を避けるため呼び出し時点で遅延requireする
				require("gtodo-md").handle_buf_enter(args.buf)
			end)
		end,
	})

	-- gtodo バッファ保存 (:w) 完了後の自動整理・全バッファ同期再開
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*.md",
		callback = function(args)
			if vim.api.nvim_buf_is_valid(args.buf) then
				local bufname = vim.api.nvim_buf_get_name(args.buf)
				if utils_mod.is_gtodo_file(bufname) then
					vim.schedule(function()
						require("gtodo-md").handle_buf_enter(args.buf)
					end)
				end
			end
		end,
	})

	-- フォーカスが戻った時の日付変更検知と全 gtodo バッファの最新一括同期
	vim.api.nvim_create_autocmd("FocusGained", {
		group = group,
		pattern = "*",
		callback = function()
			vim.schedule(function()
				if not timer_mod.should_skip_timer() then
					require("gtodo-md.daily").check_daily_rollover()
				end
			end)
		end,
	})

	-- 構文ハイライトのアタッチ
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "FileChangedShellPost" }, {
		group = group,
		pattern = "*.md",
		callback = function(ev)
			local bufname = vim.api.nvim_buf_get_name(ev.buf)
			local data_dir = require("gtodo-md.config").get("data_dir")
			if data_dir and bufname:find(data_dir, 1, true) then
				require("gtodo-md.highlight").attach(ev.buf)
			end
		end,
	})

	-- 言語変更時の即時反映のため、データディレクトリ内の.mdでBufEnter時にハイライトを更新
	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		group = group,
		pattern = "*.md",
		callback = function(args)
			local bufname = vim.api.nvim_buf_get_name(args.buf)
			local data_dir = require("gtodo-md.config").get("data_dir")
			if data_dir and bufname:find(data_dir, 1, true) then
				vim.schedule(function()
					require("gtodo-md.highlight").update_highlights(args.buf)
				end)
			end
		end,
	})

	-- projects/*.md 用 (仮想テキストの描画)
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		group = group,
		pattern = "*.md",
		callback = function(args)
			if vim.api.nvim_buf_is_valid(args.buf) then
				local bufname = vim.api.nvim_buf_get_name(args.buf)
				if require("gtodo-md.utils").is_gtodo_file(bufname) and bufname:find("projects") then
					vim.schedule(function()
						require("gtodo-md.ui").render_project_tasks(args.buf)
					end)
				end
			end
		end,
	})

	-- todo.md/inbox.md 保存時に、現在開いている全プロジェクトバッファの仮想テキストを更新する
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "inbox.md", "todo.md" },
		callback = function()
			vim.schedule(function()
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_loaded(buf) then
						require("gtodo-md.ui").render_project_tasks(buf)
					end
				end
			end)
		end,
	})

	-- setup() より前に開かれていたバッファへの遡り適用(highlight.lua と同じ理由)。
	-- autocmd は「これから発火するイベント」にしか効かないため、lazy.nvim の
	-- ft/cmd/keys 等で setup() がバッファ表示より後に走る構成では、上記の
	-- BufReadPost が既に発火し終えていてスタンプも undofile 設定も入らない。
	-- 未保存(modified)のバッファはディスクと一致していないため、スタンプは記録しない
	-- (一致していない状態を「一致」と刻印すると照合が素通りする)。
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
			local bufname = vim.api.nvim_buf_get_name(buf)
			if utils_mod.is_gtodo_file(bufname) then
				vim.bo[buf].autoread = true
				vim.bo[buf].undofile = false
				if not vim.bo[buf].modified then
					require("gtodo-md.io").record_stamp(bufname)
				end
			end
		end
	end
end

return M
