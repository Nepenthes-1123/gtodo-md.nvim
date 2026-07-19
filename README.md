# gtodo-md.nvim

[🇯🇵 日本語のドキュメントはこちら (Japanese)](README_ja.md)

A lightweight GTD (Getting Things Done) oriented Todo management plugin for Neovim, using pure Markdown.

## Features
- **Data Isolation**: Easily separate private and work tasks by changing the `data_dir` configuration.
- **GTD Oriented**: Structured with `inbox.md`, `todo.md` (Today / Next / Waiting / Someday), `done.md`, `cancelled.md`, and project files.
- **Pure Neovim Experience**: Fast task viewing via floating windows, interactive task addition/editing, and automatic due-date sorting.
- **Automated Workflow**: Moving completed tasks, promoting overdue tasks to "Today", and automatic sorting run seamlessly in the background when you open `todo.md` or `inbox.md`.
- **Rich UI Integrations**:
  - **Syntax Highlighting & Virtual Text**: Beautifully colorizes tags, contexts, priorities (`(A)`, `(B)`), and displays human-readable relative dates (e.g., "Tomorrow") via virtual text.
  - **Statusline API**: Built-in API to easily show today's remaining tasks and inbox count on your statusline (Lualine, Heirline, etc.).
  - **Dashboard Widgets**: Ready-to-use widgets to show today's tasks directly on your Neovim startup screen (Snacks Dashboard, Alpha).
  - **Advanced Picker Integrations**: Supercharged task search via `snacks.picker`, `telescope`, or `fzf-lua`. Features multi-select (`<Tab>`) and instant task toggle (`x` or `<C-x>`) directly from the search window!

## Directory Structure
The following structure is automatically generated under your specified `data_dir` (default: `stdpath("data") .. "/gtodo-md"`):
```
stdpath("data")/gtodo-md/
├── inbox.md
├── todo.md
├── done.md
├── cancelled.md
└── projects/
    └── *.md
```

## Installation & Configuration

### 1. vim.pack (Neovim v0.12+)
Add the following to your `vim.pack.add` block:
```lua
vim.pack.add({
  "https://github.com/Nepenthes-1123/gtodo-md.nvim",
})
```
Then, call setup in your configuration file:
```lua
require("gtodo-md").setup({
  -- Options (defaults are shown below)
  data_dir = vim.fn.stdpath("data") .. "/gtodo-md", 
  use_default_keymaps = true,
  picker = "auto", -- "auto" | "snacks" | "telescope" | "fzf-lua" | "builtin"
  keymap_prefix = "<Leader>t", -- Prefix for default keymaps
  due_notification_cooldown = 1800, -- Minimum interval for overdue notifications (seconds)
  due_notification_persist = true, -- Persist notification cooldown across Neovim restarts
  waiting_warning_days = 2, -- Days before warning about Waiting tasks
  enable_waiting_warning = true, -- Enable Waiting tasks warnings
  waiting_warning_interval = 3600, -- Interval to check Waiting tasks warnings (seconds)
  enable_project_progress = true, -- Display progress bars at the bottom of project files
  auto_move_inbox_to_today = true, -- Automatically move tasks with due dates of today/overdue from Inbox to Today on creation or edit
})
```

> [!NOTE]
> Even if you save files like `todo.md` as another file (`:w backup.md`), the plugin's keybindings, due-date checks, and automated tasks will always target the original files located in `data_dir`.

### 2. lazy.nvim
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

## UI Integrations

### Statusline (e.g., Lualine)
You can easily display the number of remaining tasks on your statusline:
```lua
-- Lualine
lualine_c = {
  function()
    local ok, lualine = pcall(require, "gtodo-md.integrations.lualine")
    if ok then return lualine.component()[1]() end
    return ""
  end,
}

-- Native statusline
vim.opt.statusline:append(" %{%v:lua.require('gtodo-md.api').get_statusline_string()%}")
```

### Dashboard (e.g., snacks.dashboard)
Display your tasks right when you open Neovim:
```lua
dashboard = {
  sections = {
    -- ... other sections
    function()
      local ok, gtodo = pcall(require, "gtodo-md.integrations.dashboard")
      if ok then return gtodo.snacks_section() end
      return { text = { { "gtodo-md not loaded", hl = "ErrorMsg" } } }
    end,
  }
}
```

### Pickers (Telescope / Snacks / fzf-lua)
When `picker = "auto"` is set, running `:GtodoSearch` (or `<Leader>t/`) automatically uses your installed picker. 
**Pro-tip**: You can select multiple tasks with `<Tab>`, and press `x` (Normal mode) or `<C-x>` (Insert mode) to mark them all as done directly from the picker!

## Keymaps
If `use_default_keymaps = true`, the prefix is `<Leader>t`.

### Global keymaps (available in all buffers)

| Keymap | Mode | Action |
| --- | --- | --- |
| `<Leader>tt` | Normal | Open `todo.md` in a floating window |
| `<Leader>ti` | Normal | Open `inbox.md` in a floating window |
| `<Leader>thd` | Normal | Open `done.md` in a floating window |
| `<Leader>thc` | Normal | Open `cancelled.md` in a floating window |
| `<Leader>ta` | Normal | Add/Edit task interactively (via UI prompts) |
| `<Leader>t/` | Normal | Search tasks (Tags, Contexts) using your picker |
| `<Leader>tq` | Normal | Open the Queue view (due dates grouped) |

### Buffer-local keymaps (available inside `todo.md` / `inbox.md`)

| Keymap | Mode | Action |
| --- | --- | --- |
| `<Leader>td` | Normal | Move task under cursor to `Today` section |
| `<Leader>tn` | Normal | Move task under cursor to `Next` section |
| `<Leader>tw` | Normal | Move task under cursor to `Waiting` section |
| `<Leader>ts` | Normal | Move task under cursor to `Someday` section |
| `<Leader>tx` | Normal | Toggle task completion (`[ ]` ↔ `[x]`) |
| `<Leader>tc` | Normal | Cancel task and move it to `cancelled.md` |
| `<Leader>tp` | Normal | Split task into subtasks or promote to a project |
| `<Leader>tjp` | Normal | Jump to the project file for the `+Project` tag under cursor |
| `<Leader>ttw` | Normal / Visual | Assign a `wait:` tag to the task |
| `<Leader>to` | Normal | Manually run due-date check & sort |

## Commands
- `:GtodoTodo` - Open `todo.md`
- `:GtodoInbox` - Open `inbox.md`
- `:GtodoDone` - Open `done.md`
- `:GtodoCancelled` - Open `cancelled.md`
- `:GtodoSort` - Manually sort tasks by due date and priority
- `:GtodoQueue` - Open Queue view

## License
MIT License
