-- テンプレートのアーカイブ/復元機能(未実装、先行テスト)。
--
-- projects/*.md と異なりテンプレートはfrontmatterを持たないため、
-- data_dir/templates/<name>.md を data_dir/templates/archive/<name>.md へ
-- 「移動」すること自体がアーカイブ操作になる(復元はその逆方向の移動)。
--
-- 実装は lua/gtodo-md/ui/template.lua に以下の契約で追加する想定:
--   M.list_archived_templates()  -> templates/archive/*.md の名前一覧(拡張子無し、mtime降順)。
--                                    templates/archive/ が無ければ空配列(list_templatesと同じ考え方)。
--   M.archive_template_file(name)
--     - templates/<name>.md が無ければ false(何も起きない)
--     - templates/archive/ が無ければ自動作成してから移動する
--     - templates/archive/<name>.md に既に同名ファイルがあれば false(双方とも無変更)
--     - 正常時は true(templates/<name>.md は消え、archive側に内容がそのまま移る)
--     - templates/<name>.md がロード済みバッファとして開かれている場合:
--         - バッファが未保存(dirty)でなければアーカイブは成功し、
--           バッファはアーカイブ後に解放される(bufloaded == 0)
--         - バッファが未保存(dirty)ならアーカイブは失敗し(false)、
--           元ファイル・バッファのいずれも変更しない
--   M.restore_template_file(name) -> archive_template_file と対称
--     (templates/archive/<name>.md -> templates/<name>.md、フロートバッファ危険への
--      対処もアーカイブ側のパスを対象に対称に行う)
--
-- io.move_file/io.find_buf (tests/spec/io_move_file_spec.lua) を内部で使う想定だが、
-- ここでは template.lua の公開契約のみを対象とする。

local config = require("gtodo-md.config")
local template_mod = require("gtodo-md.ui.template")

describe("ui.template アーカイブ/復元", function()
	local data_dir
	local templates_dir
	local archive_dir

	local function template_path(name)
		return string.format("%s/%s.md", templates_dir, name)
	end

	local function archived_path(name)
		return string.format("%s/%s.md", archive_dir, name)
	end

	before_each(function()
		data_dir = vim.fn.tempname()
		templates_dir = data_dir .. "/templates"
		archive_dir = templates_dir .. "/archive"
		vim.fn.mkdir(templates_dir, "p")
		config.setup({ data_dir = data_dir })
	end)

	after_each(function()
		-- ロード済みバッファがテスト間へ持ち越されないよう、生成した分を確実に解放する
		-- (force_reload_spec.lua と同じ後始末の慣習)。
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		vim.fn.delete(data_dir, "rf")
	end)

	describe("list_archived_templates", function()
		it("archiveディレクトリが無い場合は空配列を返す", function()
			assert.are.same({}, template_mod.list_archived_templates())
		end)

		it("archive/*.md のみを対象に、mtime降順で名前(拡張子無し)を返す", function()
			-- vim.fn.setftime は存在しないため、libuv の fs_utime で明示的にmtimeを前後させる
			-- (template_spec.lua の list_templates テストと同じ手法)。
			local uv = vim.uv or vim.loop
			vim.fn.mkdir(archive_dir, "p")
			vim.fn.writefile({ "- [ ] a" }, archive_dir .. "/old.md")
			vim.fn.writefile({ "not a template" }, archive_dir .. "/ignored.txt")
			local old_time = os.time() - 100
			uv.fs_utime(archive_dir .. "/old.md", old_time, old_time)
			vim.fn.writefile({ "- [ ] b" }, archive_dir .. "/new.md")
			local new_time = os.time()
			uv.fs_utime(archive_dir .. "/new.md", new_time, new_time)

			assert.are.same({ "new", "old" }, template_mod.list_archived_templates())
		end)
	end)

	describe("archive_template_file", function()
		it(
			'元のファイルが存在しない場合は (false, "notfound") を返し、何も起きない',
			function()
				local ok, reason = template_mod.archive_template_file("does-not-exist")

				assert.is_false(ok)
				assert.are.same("notfound", reason)
				assert.are.same(0, vim.fn.filereadable(template_path("does-not-exist")))
				assert.are.same(0, vim.fn.filereadable(archived_path("does-not-exist")))
				assert.are.same(
					0,
					vim.fn.isdirectory(archive_dir),
					"無関係にarchiveディレクトリを作ってはいけない"
				)
			end
		)

		it("archiveディレクトリが無ければ自動作成した上で移動する", function()
			vim.fn.writefile({ "- [ ] タスクA" }, template_path("daily-setup"))
			assert.are.same(0, vim.fn.isdirectory(archive_dir), "前提: archiveディレクトリが無いこと")

			local ok = template_mod.archive_template_file("daily-setup")

			assert.is_true(ok)
			assert.are.same(1, vim.fn.isdirectory(archive_dir))
			assert.are.same(0, vim.fn.filereadable(template_path("daily-setup")))
			assert.are.same({ "- [ ] タスクA" }, vim.fn.readfile(archived_path("daily-setup")))
		end)

		it(
			'移動先に既に同名ファイルが存在する場合は (false, "collision") を返し、双方とも変更しない',
			function()
				vim.fn.mkdir(archive_dir, "p")
				vim.fn.writefile({ "- [ ] 現役側の内容" }, template_path("dup"))
				vim.fn.writefile({ "- [ ] アーカイブ済みの内容" }, archived_path("dup"))

				local ok, reason = template_mod.archive_template_file("dup")

				assert.is_false(ok)
				assert.are.same("collision", reason)
				assert.are.same({ "- [ ] 現役側の内容" }, vim.fn.readfile(template_path("dup")))
				assert.are.same({ "- [ ] アーカイブ済みの内容" }, vim.fn.readfile(archived_path("dup")))
			end
		)

		it("正常に移動した場合、元ファイルは消えarchive側に内容がそのまま移る", function()
			vim.fn.mkdir(archive_dir, "p")
			vim.fn.writefile({ "- [ ] タスクA", "- [ ] タスクB" }, template_path("weekly"))

			local ok = template_mod.archive_template_file("weekly")

			assert.is_true(ok)
			assert.are.same(0, vim.fn.filereadable(template_path("weekly")))
			assert.are.same({ "- [ ] タスクA", "- [ ] タスクB" }, vim.fn.readfile(archived_path("weekly")))
		end)

		describe(
			"フロートバッファ危険(edit_templateがopen_float経由で開いたバッファへの回帰対策)",
			function()
				it(
					"未保存の変更が無いバッファがロード済みでも成功し、バッファは解放される",
					function()
						local path = template_path("clean-buf")
						vim.fn.writefile({ "- [ ] タスクA" }, path)

						local bufnr = vim.fn.bufadd(path)
						vim.fn.bufload(bufnr)
						assert.is_false(
							vim.bo[bufnr].modified,
							"前提: バッファが未保存(dirty)でないこと"
						)

						local ok = template_mod.archive_template_file("clean-buf")

						assert.is_true(ok)
						assert.are.same(
							0,
							vim.fn.bufloaded(path),
							"アーカイブ後もバッファがロードされたままになっている"
						)
						assert.are.same(0, vim.fn.filereadable(path))
						assert.are.same({ "- [ ] タスクA" }, vim.fn.readfile(archived_path("clean-buf")))
					end
				)

				it(
					'未保存の変更があるバッファがロード済みの場合は (false, "buffer_dirty") で失敗し、元ファイル・バッファ共に変更しない',
					function()
						local path = template_path("dirty-buf")
						vim.fn.writefile({ "- [ ] 元の内容" }, path)

						local bufnr = vim.fn.bufadd(path)
						vim.fn.bufload(bufnr)
						vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "- [ ] 未保存の追加行" })
						assert.is_true(vim.bo[bufnr].modified, "前提: バッファが未保存(dirty)であること")

						local ok, reason = template_mod.archive_template_file("dirty-buf")

						assert.is_false(ok)
						assert.are.same("buffer_dirty", reason)
						assert.are.same(1, vim.fn.filereadable(path), "元ファイルが消えている")
						assert.are.same(
							{ "- [ ] 元の内容" },
							vim.fn.readfile(path),
							"元ファイルのディスク内容が変更されている"
						)
						assert.are.same(0, vim.fn.filereadable(archived_path("dirty-buf")))
						assert.are.same(1, vim.fn.bufloaded(path), "dirtyなバッファが解放されてしまった")
						assert.is_true(vim.bo[bufnr].modified, "dirtyなバッファの未保存状態が失われた")
					end
				)

				it(
					"移動先(dst)のパスに、ファイルは無いが未保存のバッファだけが残っている場合は"
						.. '(false, "buffer_dirty") で失敗し、移動元ファイルは変更しない(#2の同一プロセス内対策)',
					function()
						local src_path = template_path("has-stale-dst-buf")
						vim.fn.writefile({ "- [ ] 現役側の内容" }, src_path)

						-- dst には現時点でファイルは存在しないが、以前のサイクルの生き残りとして
						-- バッファだけが残っている状態を再現する。
						local dst_path = archived_path("has-stale-dst-buf")
						local dst_buf = vim.fn.bufadd(dst_path)
						vim.fn.bufload(dst_buf)
						vim.api.nvim_buf_set_lines(
							dst_buf,
							-1,
							-1,
							false,
							{ "- [ ] 古いアーカイブ内容の残骸" }
						)
						assert.is_true(
							vim.bo[dst_buf].modified,
							"前提: dst側バッファが未保存(dirty)であること"
						)

						local ok, reason = template_mod.archive_template_file("has-stale-dst-buf")

						assert.is_false(ok)
						assert.are.same("buffer_dirty", reason)
						assert.are.same(1, vim.fn.filereadable(src_path), "移動元ファイルが消えている")
						assert.are.same({ "- [ ] 現役側の内容" }, vim.fn.readfile(src_path))
						assert.are.same(0, vim.fn.filereadable(dst_path))
						assert.is_true(
							vim.bo[dst_buf].modified,
							"dst側dirtyバッファの未保存状態が失われた"
						)
					end
				)
			end
		)
	end)

	describe("restore_template_file", function()
		it(
			'アーカイブ側のファイルが存在しない場合は (false, "notfound") を返し、何も起きない',
			function()
				local ok, reason = template_mod.restore_template_file("does-not-exist")

				assert.is_false(ok)
				assert.are.same("notfound", reason)
				assert.are.same(0, vim.fn.filereadable(template_path("does-not-exist")))
			end
		)

		it(
			'復元先に既に同名の現役テンプレートが存在する場合は (false, "collision") を返し、双方とも変更しない',
			function()
				vim.fn.mkdir(archive_dir, "p")
				vim.fn.writefile({ "- [ ] 現役側の内容" }, template_path("dup"))
				vim.fn.writefile({ "- [ ] アーカイブ済みの内容" }, archived_path("dup"))

				local ok, reason = template_mod.restore_template_file("dup")

				assert.is_false(ok)
				assert.are.same("collision", reason)
				assert.are.same({ "- [ ] 現役側の内容" }, vim.fn.readfile(template_path("dup")))
				assert.are.same({ "- [ ] アーカイブ済みの内容" }, vim.fn.readfile(archived_path("dup")))
			end
		)

		it("正常に復元した場合、archive側は消えtemplates側に内容がそのまま移る", function()
			vim.fn.mkdir(archive_dir, "p")
			vim.fn.writefile({ "- [ ] タスクA", "- [ ] タスクB" }, archived_path("weekly"))

			local ok = template_mod.restore_template_file("weekly")

			assert.is_true(ok)
			assert.are.same(0, vim.fn.filereadable(archived_path("weekly")))
			assert.are.same({ "- [ ] タスクA", "- [ ] タスクB" }, vim.fn.readfile(template_path("weekly")))
		end)

		describe("フロートバッファ危険(archive_template_fileと対称)", function()
			it(
				"未保存の変更が無いバッファがロード済みでも成功し、バッファは解放される",
				function()
					vim.fn.mkdir(archive_dir, "p")
					local path = archived_path("clean-buf")
					vim.fn.writefile({ "- [ ] タスクA" }, path)

					local bufnr = vim.fn.bufadd(path)
					vim.fn.bufload(bufnr)
					assert.is_false(vim.bo[bufnr].modified, "前提: バッファが未保存(dirty)でないこと")

					local ok = template_mod.restore_template_file("clean-buf")

					assert.is_true(ok)
					assert.are.same(
						0,
						vim.fn.bufloaded(path),
						"復元後もバッファがロードされたままになっている"
					)
					assert.are.same(0, vim.fn.filereadable(path))
					assert.are.same({ "- [ ] タスクA" }, vim.fn.readfile(template_path("clean-buf")))
				end
			)

			it(
				'未保存の変更があるバッファがロード済みの場合は (false, "buffer_dirty") で失敗し、アーカイブ側ファイル・バッファ共に変更しない',
				function()
					vim.fn.mkdir(archive_dir, "p")
					local path = archived_path("dirty-buf")
					vim.fn.writefile({ "- [ ] 元の内容" }, path)

					local bufnr = vim.fn.bufadd(path)
					vim.fn.bufload(bufnr)
					vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "- [ ] 未保存の追加行" })
					assert.is_true(vim.bo[bufnr].modified, "前提: バッファが未保存(dirty)であること")

					local ok, reason = template_mod.restore_template_file("dirty-buf")

					assert.is_false(ok)
					assert.are.same("buffer_dirty", reason)
					assert.are.same(1, vim.fn.filereadable(path), "アーカイブ側ファイルが消えている")
					assert.are.same(
						{ "- [ ] 元の内容" },
						vim.fn.readfile(path),
						"アーカイブ側ファイルのディスク内容が変更されている"
					)
					assert.are.same(0, vim.fn.filereadable(template_path("dirty-buf")))
					assert.are.same(1, vim.fn.bufloaded(path), "dirtyなバッファが解放されてしまった")
					assert.is_true(vim.bo[bufnr].modified, "dirtyなバッファの未保存状態が失われた")
				end
			)

			it(
				"復元先(dst)のパスに、ファイルは無いが未保存のバッファだけが残っている場合は"
					.. '(false, "buffer_dirty") で失敗し、アーカイブ側ファイルは変更しない(#2の同一プロセス内対策)',
				function()
					vim.fn.mkdir(archive_dir, "p")
					local src_path = archived_path("has-stale-dst-buf")
					vim.fn.writefile({ "- [ ] アーカイブ側の内容" }, src_path)

					local dst_path = template_path("has-stale-dst-buf")
					local dst_buf = vim.fn.bufadd(dst_path)
					vim.fn.bufload(dst_buf)
					vim.api.nvim_buf_set_lines(dst_buf, -1, -1, false, { "- [ ] 古い現役内容の残骸" })
					assert.is_true(
						vim.bo[dst_buf].modified,
						"前提: dst側バッファが未保存(dirty)であること"
					)

					local ok, reason = template_mod.restore_template_file("has-stale-dst-buf")

					assert.is_false(ok)
					assert.are.same("buffer_dirty", reason)
					assert.are.same(
						1,
						vim.fn.filereadable(src_path),
						"アーカイブ側ファイルが消えている"
					)
					assert.are.same({ "- [ ] アーカイブ側の内容" }, vim.fn.readfile(src_path))
					assert.are.same(0, vim.fn.filereadable(dst_path))
					assert.is_true(vim.bo[dst_buf].modified, "dst側dirtyバッファの未保存状態が失われた")
				end
			)
		end)
	end)
end)
