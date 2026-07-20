local logic_mod = require("gtodo-md.logic")
local task_mod = require("gtodo-md.task")

describe("logic.sort_section_tasks general sorting rules", function()

  local function make_items(...)
    local items = {}
    for _, line in ipairs({...}) do
      table.insert(items, { type = "task", task = task_mod.parse(line), line = line })
    end
    return { items = items }
  end

  it("完了済みタスクは未完了タスクより下になる", function()
    local sec = make_items(
      "- [x] 完了タスク due:2020-01-01",
      "- [ ] 未完了タスク"
    )
    local sorted = logic_mod.sort_section_tasks(sec)
    assert.are.same("未完了タスク", sorted.items[1].task.content)
    assert.are.same("x", sorted.items[2].task.status)
  end)

  it("dueありタスクはdueなしタスクより上になる", function()
    local sec = make_items(
      "- [ ] dueなし",
      "- [ ] dueあり due:2025-01-01"
    )
    local sorted = logic_mod.sort_section_tasks(sec)
    assert.are.same("dueあり", sorted.items[1].task.content)
    assert.are.same("dueなし", sorted.items[2].task.content)
  end)

  it("due日付の古い順(昇順)になる", function()
    local sec = make_items(
      "- [ ] タスク2 due:2025-02-01",
      "- [ ] タスク1 due:2025-01-01"
    )
    local sorted = logic_mod.sort_section_tasks(sec)
    assert.are.same("タスク1", sorted.items[1].task.content)
    assert.are.same("タスク2", sorted.items[2].task.content)
  end)

  it("dueが同じ場合、優先度順になる", function()
    local sec = make_items(
      "- [ ] (B) タスクB due:2025-01-01",
      "- [ ] (A) タスクA due:2025-01-01"
    )
    local sorted = logic_mod.sort_section_tasks(sec)
    assert.are.same("タスクA", sorted.items[1].task.content)
    assert.are.same("タスクB", sorted.items[2].task.content)
  end)

  it("dueも優先度も同じ場合、元の順序が維持される(stable sort)", function()
    local sec = make_items(
      "- [ ] タスクB due:2025-01-01",
      "- [ ] タスクA due:2025-01-01"
    )
    local sorted = logic_mod.sort_section_tasks(sec)
    -- タスクBが先だったなら、ソート後もタスクBが先
    assert.are.same("タスクB", sorted.items[1].task.content)
    assert.are.same("タスクA", sorted.items[2].task.content)
  end)

end)
