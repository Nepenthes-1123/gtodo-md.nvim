local M = {}

-- float.lua (状態と基本フローと管理)
M.open_float = require("gtodo-md.ui.float").open_float
M.open_todo_float = require("gtodo-md.ui.float").open_todo_float
M.open_inbox_float = require("gtodo-md.ui.float").open_inbox_float
M.open_done_float = require("gtodo-md.ui.float").open_done_float
M.open_cancelled_float = require("gtodo-md.ui.float").open_cancelled_float

-- queue.lua
M.open_queue = require("gtodo-md.ui.queue").open_queue

-- kanban.lua
M.open_kanban = require("gtodo-md.ui.kanban").open_kanban

-- search.lua
M.search_tasks = require("gtodo-md.ui.search").search_tasks

-- project.lua
M.jump_to_project = require("gtodo-md.ui.project").jump_to_project
M.render_project_tasks = require("gtodo-md.ui.project").render_project_tasks

-- prompt_task
M.prompt_task = require("gtodo-md.ui.prompt").prompt_task

-- template.lua
M.edit_template = require("gtodo-md.ui.template").edit_template
M.insert_template = require("gtodo-md.ui.template").insert_template

return M
