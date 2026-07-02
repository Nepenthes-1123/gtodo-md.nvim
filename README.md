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
指定した `data_dir`（未指定時のデフォルト: `stdpath("data") .. "/todo"`）配下に以下の構造が自動生成されます。
```
stdpath("data")/todo/
├── inbox.md
├── todo.md
├── done.md
├── cancelled.md
└── projects/
    └── *.md
```

## インストールと設定

### lazy.nvim の場合
```lua
{
  "gtodo-md.nvim",
  dir = "~/development/gtodo-md.nvim", -- 開発用パス
  config = function()
    require("gtodo_md").setup({
      -- 必要に応じてデータ保存先を変更してください
      data_dir = vim.fn.expand("~/todo/personal"), 
      use_default_keymaps = true,
      -- タスク検索時のファインダー指定 ("auto" | "snacks" | "telescope" | "fzf-lua" | "builtin")
      picker = "auto", 
    })
  end
}
```

## キーバインド

### グローバルキーマップ (すべてのバッファで有効)
| キー | 動作 |
|---|---|
| `<Leader>tt` | `todo.md` をフローティング表示で開く |
| `<Leader>ti` | `inbox.md` をフローティング表示で開く |
| `<Leader>ta` | 空行や他のバッファでは新規タスク追加。タスク行にいる場合はタスクの編集。 |
| `<Leader>t/` | タグ（`+`）、コンテキスト（`@`）、完了状態（`[ ]` / `[x]`）でのAND検索 |

### バッファローカルキーマップ (`todo.md` / `inbox.md` でのみ有効)
| キー | 動作 |
|---|---|
| `<Leader>td` | カーソル行を `Today` セクションへ移動 |
| `<Leader>tn` | カーソル行を `Next` セクションへ移動 |
| `<Leader>tw` | カーソル行を `Waiting` セクションへ移動 |
| `<Leader>ts` | カーソル行を `Someday` セクションへ移動 |
| `<Leader>tx` | `[ ]` / `[x]` をトグル（完了時に `completed_at:YYYY-MM-DD` を付与） |
| `<Leader>tc` | カーソル行のタスクをキャンセルし、`cancelled.md` へ移動 |
| `<Leader>tjp` | カーソル上の `+プロジェクト名` から対応するプロジェクトファイルへジャンプ（存在しない場合はテンプレートから自動作成） |
| `<Leader>to` | 手動での期日チェック & 自動ソート実行 |

## コマンド
- `:GtodoSort` : `todo.md` を手動で期日順にソートします。
- `:GtodoSearch` : タグやコンテキストでタスクをAND絞り込み検索します。
