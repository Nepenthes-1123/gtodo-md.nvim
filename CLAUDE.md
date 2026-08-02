# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

gtodo-md.nvim は、プレーンな Markdown ファイル（`inbox.md`, `todo.md`, `done.md`, `cancelled.md`, `projects/*.md`）を裏付けとする、GTD 志向の Todo 管理を実装した Neovim プラグイン（純粋な Lua）です。ビルドステップは存在せず、`lua/` 配下から直接実行されます。

リポジトリ構成に関する注意: このチェックアウトは、親ディレクトリの bare リポジトリから作られたブランチごとの git worktree の1つです。他のブランチ用の worktree が兄弟ディレクトリとして存在する場合があります。

## コマンド

Lua 5.1 のツールチェインと、PATH 上の Neovim が必要です。`plenary.nvim` が利用可能である必要があります（`stdpath("data")/site/pack/core/opt/plenary.nvim` に存在するか、リポジトリルートからの相対パス `./plenary` として存在すること — `tests/minimal_init.lua` を参照）。

```sh
# フルテストスイートを実行する（headless Neovim + plenary の busted 形式スペック）
nvim --headless -u tests/minimal_init.lua -S tests/run_tests.lua

# 単一のスペックファイルを実行する
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/spec/logic_sort_spec.lua"

# Lint
luarocks install luacheck   # 初回のみ
luacheck lua/ tests/

# フォーマットチェック / フォーマット
stylua --check lua/ tests/
stylua lua/ tests/
```

CI（`.github/workflows/ci.yml`）は luacheck と stylua の `--check` を実行し、Neovim `v0.10.0` と `nightly` の両方に対してテストを実行します。

スタイル設定: タブインデント、幅4、列幅120、ダブルクォート文字列を優先（`stylua.toml`）。Luacheck は `lua51` をターゲットとし、グローバル `vim` を許可、行の長さに関する警告は無視します（`.luacheckrc`）。

## アーキテクチャ

### モジュール構成

- `init.lua` — エントリーポイント（`M.setup`）。config・autocmd・keymap・ユーザーコマンドをここで結線する。キーマップ/コマンドから呼ばれる2つの大きな「適応的」エントリーポイント、`add_or_edit_task()` と `sort_and_check_dues()` もここにある。横断的な振る舞い（autoread、バッファ再読み込みのオーケストレーション、保存時バリデーションの結線）の大部分はここの `setup_autocmds()` にある — 保存/リロード周りを触る前に必ず読むこと。バリデーションの判定ルール自体は `validate.lua` へ切り出されており、`setup_autocmds()` の各コールバックは「対象バッファか判定 → バッファ行を取得 → `validate.lua` に問い合わせ → エラーメッセージを組み立てて `error(msg, 0)`」に徹する。
- `validate.lua` — 保存時バリデーション（`BufWritePre`）の判定ルールを純関数として持つ。`missing_todo_sections`（必須セクションの不足。`config.section_aliases` 経由でカスタム名・デフォルト名の両方を受理する #94）、`has_required_header`、`collect_history_sections`/`missing_history_sections`（`## YYYY-MM` の削除保護）、`extract_frontmatter_created`、`validate_project_frontmatter`（エラー文字列のリストを返す。空なら妥当）。引数はプレーンな値（行のリスト等）のみで、`vim.api`・バッファ・ファイルパスには一切触れない。バッファが `data_dir` 配下かどうかの判定(#91)、キャッシュ（`original_created_dates`/`original_history_sections`）の保持、ユーザー向けエラーメッセージの組み立ては呼び出し元（`init.lua`）の責務。
- `config.lua` — デフォルト値と `M.options`/`M.get(key)` アクセサ、およびセクション名の正本（`config.sections.TODAY/NEXT/WAITING/SOMEDAY`）。`setup({sections=...})`(#94)でキー単位に上書きできる(部分上書き可)。`M.default_sections`は変更されない固定のデフォルト名。`M.section_aliases(key)`はそのキーに対して現在有効な名称候補を返す — 優先順に「現在のカスタム名」「デフォルト名」「前回のsetup()で使われていた名前(`utils.read_last_sections`/`write_last_sections`で`.state.json`に永続化)」の最大3つ。デフォルト名は常にエイリアスとして受理され続けるため、カスタム化後も既存ファイルの見出しを手動でリネームする必要がない。さらに前回の名前も1世代分だけ記憶しているため、カスタム名を変更・削除した直後(ファイルの見出しがまだ前回の名前のまま)でも保存がブロックされない(`io.lua`の`parse_markdown`がその場で現在の名前へ正規化し、次回保存時に書き戻る。`init.lua`の`BufWritePre`バリデーションも`section_aliases`経由で全候補を許容する)。全履歴ではなく直前の1世代分のみを覚える設計であることに注意。
- `task.lua` — タスク行の文法定義。`M.parse(line)` は `- [ ] ...` 形式の markdown 行をタスクテーブル（`status`, `content`, `priority`, `due`, `created`, `context`, `project`, `wait`, `completed_at`, `done`, `cancelled`, `from`, `id`）に変換し、`M.serialize(task)` は逆に行へ戻す。これはディスク上のタスクフォーマットの唯一の正本であり、`serialize` での末尾タグの順序はラウンドトリップテストに影響する。`id` は一意なタスク識別子（6桁16進、`M._generate_id()` が `vim.loop.hrtime()` とプロセスIDから発行）で、`serialize` 時に未発行なら自動発行され行末に付与される。既に発行済みのIDは上書きされない。パース自体は非空白文字列であれば値の形式を問わず受け付ける（手編集等で非16進の値が入っていても、行末アンカー方式の抽出が連鎖的に壊れないようにするため）。
- `io.lua` — markdown ファイルの I/O と構造パース。`read_lines` は、開いているバッファがあればファイルシステムより優先して透過的に使用する（未保存の編集内容も含めて読み取るため）。`write_lines` は `nvim_buf_call` + `:write` を使わない — バッファが開いている場合は直接内容を差分反映して `modified` フラグをクリアするに留め、ディスクへは別途アトミックに（`.tmp` に書いてから rename）書き込む。これは自動処理によるカレントバッファの一瞬の切り替え（画面のちらつき）や、`BufWritePre` 等の意図しないautocmd発火を避けるためであり、バッファが未保存(dirty)であっても常に保存する。書き込み後は対象バッファ番号を指定した `checktime` でVim内部のファイル更新時刻の追跡を同期し、後続の編集でVimが自分自身の書き込みを外部変更と誤認しないようにしている。`parse_markdown`/`write_todo_file` は todo ファイルを `{ header, sections: { [name] = items }, section_order }` としてモデル化しており、`items` は `{type="task", task=...}` / `{type="text", line=...}` のフラットなリストである。`### 見出し`はタスクとして構造化されず、他の非タスク行と同じ `type="text"` の1アイテムとして元の位置にそのまま保持される（#86/#90 で判明した「サブセクションをネスト構造 `{items, subsections}` として扱っていたことに起因する不具合の多発」を受けて撤廃した設計 — 詳細は後述）。`write_todo_file` はファイル書き出し1回分(全セクション)を通してタスクIDの重複を検知し、コピー&ペーストで複製された分は再発行する(ファイル内で最初に登場した方が元のIDを保持する)。書き出しの最後に`collapse_blank_runs`で連続する空行を1行へ圧縮する(markdownlint MD012対策) — `data.header`(最初の`## `見出しより前の行)はセクション内の`items`と異なり空行をフィルタせずそのままechoするため、これが無いと手編集等でヘッダー部分に連続空行があった場合に書き戻しても残り続けてしまう。
- `logic/` — タスクリストに対する純粋な操作群。`logic/init.lua` でフラットに re-export されている:
  - `sort.lua` — 並び順のルール（未完了が完了より上、due日付の昇順、次に優先度、それ以外は安定ソート — 正確な仕様は `tests/spec/logic_sort_spec.lua` を参照）。非タスク行(`### 見出し`を含む任意のテキスト行)は並び替えの境界として扱われ、その行を挟んだタスク同士が入れ替わることはない(境界で区切られた連続するタスクの区間ごとに独立してソートする)。安定ソートのタイブレークに使う`original_index`は、内部専用の使い捨てラッパー(`{item=item, original_index=i}`)にのみ持たせ、引数の`item`そのものには一切書き込まない(#96 — 以前は`item.original_index`を直接書き込んでおり、呼び出し元が同じitemを保持し続ける限り内部実装の詳細が漏れ出るリスクがあった)。
  - `due.lua` — due日付の評価/昇格（例: inbox → Today）。複数インスタンス間の既知の残存リスク(関数冒頭のコメント参照)についてもここに記載。
  - `completion.lua` — 完了タスクを todo.md から done.md へ移動する処理。
  - `history.lua` — `done.md`/`cancelled.md` の `## YYYY-MM` 見出し配下へのエントリ追記。`io_mod.read_lines` 経由でバッファの未保存内容を考慮して読む。
- `lock.lua` — 自動処理（due チェック・ソート・日次ロールオーバー）全般で共有する排他ロック（`data_dir/.gtodo.lock`、O_EXCL相当のアトミックなファイル作成）。`with_write_lock(data_dir, fn)` は取得できた場合のみ `fn` を実行し、取得できなければ待機・リトライせず `false` を返す（呼び出し元はその回を諦めて次のトリガーに委ねる）。キーマップ経由のユーザー操作（editor.lua）はこの対象外。
- `daily.lua` — 日付変更（ロールオーバー）の検知とオーケストレーション（完了タスクの履歴への繰り込み、due到達タスクの昇格）を行う。日付ゲート（`last_opened` の永続化）により1日1回しか実行されない。ロック自体は `lock.lua` を利用する。また、ディスク上のファイルが開いているバッファの外側で変更された際に使う、バッファの autoread/checktime ヘルパー `reload_managed_bufs()` もここにある。mtimeキャッシュは**用途別に2つ独立**している: `get_cache()`/`update_cache()` で公開され `init.lua` の `handle_buf_enter` が「自前のdueチェック・ソートを再実行すべきか」を判定するための `last_processed_mtimes` と、`reload_if_externally_changed`(他インスタンスによる外部変更検知)専用の非公開な `external_change_mtimes`。同じキャッシュを共有すると、一方の判定が先に変化を消費してしまいもう一方が二度と検知できなくなる不具合があったため分離した(ロールオーバー成功直後のみ両方を更新する)。`last_processed_mtimes`(#89)には対になる `last_processed_sizes` があり、`handle_buf_enter` はmtime(秒精度)に加えてファイルサイズも比較することで、同一秒内の連続変更の一部を追加で検知する(同一秒内でサイズも変わらない変更は低確率のため許容)。`get_cache()`(#98)は内部キャッシュテーブルの参照ではなくシャローコピーを返すため、呼び出し側が戻り値を書き換えても内部状態は汚染されない。
- `editor.lua` — バッファローカルなキーマップから呼ばれる、カーソル位置に対する操作群（完了トグル、セクション間のタスク移動、キャンセル、`wait:` タグの付与）。ソートによって行が並び替わるため、編集を跨いだタスクの同一性判定は `M._find_task_idx` で行っており、`id` 完全一致(Primary) → `original_line` 完全一致(Secondary) → `content` + `created` 一致(Fallback) の順に照合する。IDがまだ発行されていない(保存サイクルを経ていない)タスクはSecondary/Fallbackで解決される。
- `split.lua` — タスクをサブタスクへ分割する処理、またはプロジェクトファイルへ昇格させる処理。Extmarkが破壊された場合の最終手段(Deep Fallback)は行テキストの完全一致+最近傍距離で親タスク行を探すが、タスクIDがserialize時に行へ組み込まれるようになったため、保存済みタスク同士が偶然テキスト衝突するケースは実質的に排除されている。分割ポップアップの多重起動防止ロック(`active_splits`)は、タスク行(チェックボックス行)なら`task.id`を、idを持たない素のリスト項目なら`right_gravity=true`の専用extmark(コミット用の親行追跡extmarkとは別物 — `right_gravity=false`は行そのものの挿入には追従しないため)の現在位置を、それぞれロックキーとして使う(#92)。id未発行のタスクはロック開始時にその場でidを発行し行末へ埋め込む。ロック解放は`BufWipeout`と`WinClosed`の両方から同じ冪等な関数を呼ぶことで、ポップアップが`:q`以外の方法で閉じられてもゾンビロックが残らないようにしている。
- `ui/` — インタラクティブ/ビジュアルな UI 一式。`ui/init.lua` で re-export されている: `float.lua`（todo/inbox/done/cancelled のフローティングウィンドウビューア）、`queue.lua`（due日付でグルーピングした Queue ビュー。ファイルをバッファ化する際、未ロード分は `eventignore` で `BufRead` 系autocmdの誤発火を抑制する）、`search.lua`（タグ/コンテキスト検索のディスパッチ）、`project.lua`（プロジェクトファイルへのジャンプ + 進捗の virtual text 描画）、`prompt.lua`（タスクの追加/編集入力 UI）。
- `integrations/` — 外部プラグイン向けの任意の連携: `lualine.lua`、`dashboard.lua`（snacks/alpha 用ウィジェット）、`picker.lua`（`config.picker` で選択される snacks.picker/telescope/fzf-lua の検索+トグルバックエンド）。
- `api.lua` — statusline/dashboard 連携向けの小さく安定した公開インターフェース（例: `get_statusline_string`）。
- `highlight.lua` — gtodo バッファに対する構文ハイライトと virtual text（相対的な due日付表示）。行末の `id:` タグは人間が読む必要のない内部識別子のため `conceal` で隠す（`M.setup()` で `concealcursor` を空にしているため、カーソルがその行にある間は自動的に見える状態に戻り通常通り編集できる — バッファの中身自体は一切変更しない、あくまで表示上の機能）。`conceallevel`/`concealcursor` はウィンドウローカルオプションのため `BufWinEnter` で `data_dir` 配下のバッファを表示するウィンドウに設定している。
- `timer.lua` — バックグラウンドタイマー（Waiting タスクの警告、日次ロールオーバーチェック）。`should_skip_timer()` はノーマルモードかどうかのみを見る（未保存バッファの有無はもう見ない — 下記参照）。
- `utils.lua` — 共有ヘルパー。due日付文字列のパース/正規化、`is_gtodo_file`（バッファが `data_dir` に属するかどうかのパスベースの判定）などを含む。`parse_due_date` の相対日付 `+Nm`/`+Ny` は固定日数(30日/365日)ではなく暦算(`add_months`)で「翌月/翌年の同日」を計算する(#88)。対象月に存在しない日(例: 1/31 + 1ヶ月、閏日 + 1年)はその月の末日へクランプし、次の月へ繰り越さない。`+Nd`/`+Nw` は従来通り固定日数のまま。

### 編集前に把握しておくべきデータモデルと不変条件

- タスク行は単一行の markdown チェックボックスで、末尾にスペース区切りのタグ（`+project`, `@context`, `due:`, `created:`, `wait:`, `completed_at:`, `done:`, `cancelled:`, `from:`）を持ち、任意で先頭に `(A)` のような優先度が付く。この文法を知っているべきなのは `task.lua` のみ。
- `todo.md` には常に `## Today`, `## Next`, `## Waiting`, `## Someday` が含まれていなければならない — `init.lua` の `BufWritePre` バリデータで強制されており、必須のセクション見出しが欠けていると例外を投げて保存を中断する。
- `inbox.md`/`done.md`/`cancelled.md` にはそれぞれ独自の `BufWritePre` ガードがある: 必須のトップヘッダー（`# Inbox`/`# Done`/`# Cancelled`）が失われないこと、また `done.md`/`cancelled.md` については、バッファ読み込み時に存在していた `## YYYY-MM` 見出しが保存時に削除されていないこと（`BufReadPost`/`BufEnter` 時にバッファごとのキャッシュへ記録して追跡している）。
- `projects/*.md` ファイルは `title`, `tag`, `created`, `due`, `status`, `members` を含む YAML フロントマターを必須とする。`tag` はファイル名（拡張子なし）と一致していなければならず、`created` は一度設定されたら変更不可 — これらも `init.lua` の別の `BufWritePre` ガードで強制されている。
- これら`BufWritePre`ガードのautocmd `pattern` はファイル名の末尾一致のみのため、`utils.is_gtodo_file`でバッファパスが実際に`data_dir`配下かどうかを各コールバックの先頭で確認している(#91)。これが無いと、ユーザーが`data_dir`と無関係な場所で偶然同名(`todo.md`等)のファイルを保存しようとした際にもgtodo-md固有のバリデーションで保存がブロックされてしまう。
- **自動処理（due チェック・ソート・日次ロールオーバー）の書き込みは、対象バッファが未保存(dirty)かどうかに関わらず常に実行・保存される。** 読み込みは常にライブバッファの内容（未保存分を含む）を参照するため、自動処理による変更とユーザーの未保存編集はマージされて保存され、失われることはない。以前存在した「未保存バッファがあれば自動処理を丸ごとスキップする」ゲート（`handle_buf_enter` の `has_modified_gtodo`、`should_skip_timer` のバッファ走査）は廃止済み。`handle_buf_enter` の mtime キャッシュによるスキップ判定は純粋な性能最適化であり、対象バッファ自身が dirty な場合は mtime が変化していなくてもスキップしない。
- `## セクション` 配下の `### 見出し`（サブセクション）は構造化データとして扱わない。以前は `{items, subsections}` というネスト構造でパースし、`sort.lua` を含む各所が `subsections` を意識して走査する設計だったが、この前提を漏れなく守るのは実質的に困難で、`editor.lua`(完了トグル・移動・キャンセル)・`due.lua`(due到達タスクの読み取り側)・`completion.lua`・`timer.lua`・`project.lua`・`dashboard.lua` の計6箇所で「`### 見出し`配下のタスクが見えない/操作できない」不具合が積み重なっていた(#86, #90)。`###` 見出しはユーザー向けドキュメントにも存在しない非公式な機能だったため、構造化をやめて他のテキスト行と同じ `type="text"` のフラットなアイテムとして扱う設計に単純化した。見出し行の周囲の空行は(他の任意のテキスト行と同様)保存時に特別扱いで再挿入されない。
- `logic/`配下の関数は、内部実装のためだけの一時的な状態(ソート時のインデックス等)を引数のitem/taskオブジェクトへ直接書き込まない(#96)。呼び出し元がそのオブジェクトを保持し続ける限り、内部実装の詳細が漏れ出てキャッシュ汚染や意図しない副作用の原因になり得るため。既存のtask実データそのものの更新(`status`/`wait`/`completed_at`等、ユーザーが実際に変更したい内容)は対象外 — あくまで呼び出し元に無関係な内部専用の一時フィールドが対象。
- 同じ `data_dir` を複数の Neovim インスタンスが同時に共有し得る。自動処理（due チェック・ソート・ロールオーバー）は `lock.lua` の共有排他ロックにより複数インスタンス間で一度だけ実行される。ロックを取得できなければ待機・リトライせず、その回は諦めて次のトリガーに委ねる。他インスタンスの未保存内容は関知・保証しない（各インスタンスは自分が保有するバッファについてのみ責任を持つ）。この設計上、`check_dues`（`logic/due.lua`）には低確率の既知の残存リスクが残っている — 詳細は同ファイルの `M.check_dues` 冒頭のコメントを参照。

### ローカライズに関する注意

ソースコードのコメントとテストの説明文は日本語で書かれている（主要メンテナーの言語）。一方、ユーザー向けの `vim.notify` の文字列や識別子は英語である。全体を一括で変換するのではなく、編集するファイルに既にある慣習に合わせること。
