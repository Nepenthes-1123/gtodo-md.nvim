local M = {}

M.sort_section_tasks = require("gtodo-md.logic.sort").sort_section_tasks
M.sort_todo_file = require("gtodo-md.logic.sort").sort_todo_file
M.check_dues = require("gtodo-md.logic.due").check_dues
M.append_to_history = require("gtodo-md.logic.history").append_to_history
M.move_completed_tasks = require("gtodo-md.logic.completion").move_completed_tasks

return M
