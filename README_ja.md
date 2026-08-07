# gtodo-md.nvim

GTD（Getting Things Done）の軽量版を Neovim 内で Markdown を使用して実現するための Todo 管理プラグインです。

## 特徴
- **PCごとのデータ分離**: 設定で `data_dir` を切り替えるだけで、プライベート用/仕事用のタスクデータを完全分離できます。
- **GTD指向 of GToDo**: Inbox, Todo (Today / Next / Waiting / Someday), Done, Cancelled のファイル及びプロジェクトファイルで構成されます。
- **Neovim内完結**: フローティングウィンドウでの素早いタスク閲覧、対話型でのタスク追加・編集、自動期日順ソートが利用可能です。
- **自動処理**: `todo.md` や `inbox.md` を開いた際に、完了タスクの移動、期日切れタスクの自動昇格、自動ソートがバックグラウンドで実行されます。
- **タイマー機能**: Neovim 起動中の日付変更検知によるタスク移動や、Waiting タスクの期日通知（1時間おき）が動作します。
- **AND絞り込み検索**: クイックフィックスリストを利用した、タグ・コンテキスト・完了状態でのAND検索が可能です。

## ディレクトリ構成
指定した `data_dir`（未指定時のデフォルト: `stdpath("data") .. "/gtodo-md"`）配下に以下の構造が自動生成されます。
```
stdpath("data")/gtodo-md/
├── inbox.md
├── todo.md
├── done.md
├── cancelled.md
└── projects/
    └── *.md
```

## インストールと設定

### 1. vim.pack (Neovim v0.12+ 組み込み) の場合
`plugins/init.lua` 等の `vim.pack.add` の中に以下を追記します。
```lua
vim.pack.add({
  "https://github.com/Nepenthes-1123/gtodo-md.nvim",
})
```
そして、設定ファイル（`init.lua` など）でセットアップを実行します。
```lua
require("gtodo-md").setup({
  -- オプション (省略した場合はデフォルト値が使用されます)
  data_dir = vim.fn.stdpath("data") .. "/gtodo-md", 
  use_default_keymaps = true,
  picker = "auto", -- "auto" | "snacks" | "telescope" | "fzf-lua" | "builtin"
  keymap_prefix = "<Leader>t", -- キーマップの接頭辞 (他のプラグインと競合する場合は変更してください)
  due_notification_cooldown = 1800, -- 期限切れ通知の最小間隔 (秒)。デフォルト 30 分
  due_notification_persist = true, -- Neovim 終了後も通知制限時間を維持するかどうか (false で起動中のみ)
  waiting_warning_days = 2, -- Waiting タスクの期限警告日数 (デフォルト 2 日)
  enable_waiting_warning = true, -- Waiting タスクの期限警告通知を有効にするかどうか (デフォルト true)
  waiting_warning_interval = 3600, -- Waiting タスク警告のチェック間隔 (秒) (デフォルト 3600 秒 = 1時間)
  enable_project_progress = true, -- プロジェクトファイル最下部に進捗バーを表示するかどうか (デフォルト true)
  auto_move_inbox_to_today = true, -- Inbox内でタスクを追加・編集した際、期日が「今日・過去」であれば自動的にTodayへ移動するかどうか
  sections = { -- todo.md のセクション名をカスタマイズ(一部のキーだけの上書きも可)
    TODAY = "Today",
    NEXT = "Next",
    WAITING = "Waiting",
    SOMEDAY = "Someday",
  },
})
```

> [!NOTE]
> `todo.md` などのファイルを `:w backup.md` 等で別名保存した場合でも、プラグイン側の各種キーバインド、期限チェック、自動移動処理は常に `data_dir` に設定された元のタスクファイルを対象にして動作し続けます。

> [!NOTE]
> 既にプラグインを使い始めた後で `sections` をカスタマイズしても、`todo.md` 内の既存の `## Today`/`## Next`/`## Waiting`/`## Someday` 見出しはそのまま動作し続けます(手動でのリネームは不要です)。次回保存時に自動的に認識され、カスタム名へ書き換えられます。


### 2. lazy.nvim の場合
```lua
{
  "Nepenthes-1123/gtodo-md.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("gtodo-md").setup({
      use_default_keymaps = true,
      picker = "auto",
    })
  end
}
```

### 3. pckr.nvim の場合
```lua
require('pckr').add({
  { 'Nepenthes-1123/gtodo-md.nvim',
    requires = { 'nvim-lua/plenary.nvim' },
    config = function()
      require('gtodo-md').setup({
        use_default_keymaps = true,
        picker = "auto",
      })
    end
  };
})
```

### 4. mini.deps の場合
```lua
local MiniDeps = require('mini.deps')
MiniDeps.add({
  source = 'Nepenthes-1123/gtodo-md.nvim',
  depends = { 'nvim-lua/plenary.nvim' }
})
require('gtodo-md').setup({
  use_default_keymaps = true,
  picker = "auto",
})
```

## キーバインド

デフォルトでは `<Leader>t` がキーマップの接頭辞（プレフィックス）として使用されます。

### キーバインドのカスタマイズと競合対策
`<Leader>t` が他のプラグイン（ターミナル呼び出しや Telescope など）と競合する場合は、`setup` オプションの `keymap_prefix` を使用して**接頭辞を一括で変更**できます。

また、`keymap_prefix` は 3打キー（例: `<Leader>to`）に設定して、キーの階層を深くすることも可能です。

#### 設定例（接頭辞を `<Leader>o` (Organizerの頭文字) に一括変更する場合）:
```lua
require("gtodo-md").setup({
  keymap_prefix = "<Leader>o", 
})
```
これにより、Todoを開くキーは `<Leader>ot`、タスク追加は `<Leader>oa` のように一括で安全に変更されます。

#### 設定例（キーバインドを完全に無効化して個別に割り当てる場合）:
```lua
require("gtodo-md").setup({
  use_default_keymaps = false, -- デフォルトキーマップを登録しない
})

-- 個別に好きなキーで割り当てる
vim.keymap.set('n', '<Leader>tt', function() require('gtodo-md.ui').open_todo_float() end, { desc = "Toggle Todo float" })
vim.keymap.set('n', '<Leader>ta', function() require('gtodo-md').add_or_edit_task() end, { desc = "Add or edit task" })
```

### グローバルキーマップ (すべてのバッファで有効、以下はデフォルト `<Leader>t` の例)
| キー | 動作 |
|---|---|
| `<Leader>tt` | `todo.md` をフローティング表示で開く |
| `<Leader>ti` | `inbox.md` をフローティング表示で開く |
| `<Leader>thd` | `done.md` (完了履歴) をフローティング表示で開く |
| `<Leader>thc` | `cancelled.md` (キャンセル履歴) をフローティング表示で開く |
| `<Leader>ta` | 空行や他のバッファでは新規タスク追加。タスク行にいる場合はタスクの編集。 |
| `<Leader>tq` | Queue ビューを開く（期限付きタスクを日付順に一覧表示） |
| `<Leader>t/` | タグ（`+`）、コンテキスト（`@`）、完了状態（`[ ]` / `[x]`）でのAND検索 |

### バッファローカルキーマップ (`todo.md` / `inbox.md` でのみ有効、以下はデフォルト `<Leader>t` の例)
| キー | 動作 |
|---|---|
| `<Leader>td` | カーソル行を `Today` セクションへ移動 |
| `<Leader>tn` | カーソル行を `Next` セクションへ移動 |
| `<Leader>tw` | カーソル行を `Waiting` セクションへ移動し、待ち先（`wait:`）を対話的に設定（空入力で削除）。既に `Waiting` にいる場合はセクションを移動せず `wait:` のみ更新 |
| `<Leader>ts` | カーソル行を `Someday` セクションへ移動 |
| `<Leader>tx` | `[ ]` / `[x]` をトグル（完了時に `completed_at:YYYY-MM-DD` を付与） |
| `<Leader>tc` | カーソル行のタスクをキャンセルし、`cancelled.md` へ移動 |
| `<Leader>tp` | タスクを分割してサブタスク化（Split）、またはプロジェクトへ昇格（Promote） |
| `<Leader>tjp` | カーソル上の `+プロジェクト名` から対応するプロジェクトファイルへジャンプ（存在しない場合はテンプレートから自動作成） |
| `<Leader>to` | 手動での期日チェック & 自動ソート実行 |

> [!NOTE]
> `wait:` は `Waiting` セクションに属するタスクの情報として扱われます。`Today` / `Next` / `Someday` へ移動すると `wait:` は削除されます。
> また `Waiting` のタスクは、期日が来ても `Today` へ自動昇格しません（自動昇格の対象は `Inbox` / `Next` / `Someday` です）。

## コマンド
- `:GtodoTodo` : `todo.md` をフローティング表示で開きます。
- `:GtodoInbox` : `inbox.md` をフローティング表示で開きます。
- `:GtodoDone` : `done.md` をフローティング表示で開きます。
- `:GtodoCancelled` : `cancelled.md` をフローティング表示で開きます。
- `:GtodoSort` : `todo.md` を手動で期日順にソートします。
- `:GtodoSearch` : タグやコンテキストでタスクをAND絞り込み検索します。
- `:GtodoQueue` : Queue ビューを開きます。期限付き未完了タスクを「期限切れ / 今日〜7日後 / それ以降」のグループで一覧表示します。

## 複数の Neovim を同時に使う場合

同じ `data_dir` を複数の Neovim インスタンスで同時に開けます。インスタンス間の同期を保つため、gtodo-md は管理対象ファイル（`inbox.md` / `todo.md` / `done.md` / `cancelled.md` / `projects/*.md`）について **ディスク上のファイルを正** として扱います。これに伴い、次の2点が通常の Neovim と異なります。

- **ディスクが変わった時点で、未保存の編集は破棄されます。** あるファイルに未保存の変更を持った状態で、他インスタンス（あるいは同期ソフトや `git pull` などの外部ツール）が同じファイルを書き換えると、`[O]K, (L)oad File:` の確認プロンプトを出さずにディスクの内容へ再読み込みします。破棄された編集は `u`（undo）で戻せます。
- **これらのバッファでは永続 undo（`'undofile'`）を無効にします。** undo ファイルはプロセス間でロックされないため、複数インスタンスが同じファイルをリロードすると同一の undo ファイルを奪い合い、`E828: Cannot open undo file for writing` が発生します。バッファ内の undo は従来どおり使えます。

いずれも `data_dir` 配下のファイルにのみ適用され、それ以外のファイルの設定には影響しません。

## ライセンス
MIT License
