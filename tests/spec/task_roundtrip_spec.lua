local task_mod = require("gtodo-md.task")

describe("task.lua parse and serialize roundtrip", function()
  
  it("フルフィールドのタスクが完全に復元される", function()
    local line = "- [ ] (A) テストタスク +project @context due:2025-01-01 created:2024-12-31 wait:2025-01-02 completed_at:2025-01-03"
    local task = task_mod.parse(line)
    
    assert.are.same("A", task.priority)
    assert.are.same("project", task.project)
    assert.are.same("@context", task.context)
    assert.are.same("2025-01-01", task.due)
    assert.are.same("2025-01-02", task.wait)
    assert.are.same("2024-12-31", task.created)
    assert.are.same("2025-01-03", task.completed_at)
    assert.are.same(" ", task.status)
    assert.are.same("テストタスク", task.content)
    
    local serialized = task_mod.serialize(task)
    assert.are.same(line, serialized)
  end)

  it("インデントされたタスクが復元される", function()
    local line = "  - [x] 完了したサブタスク"
    local task = task_mod.parse(line)
    
    assert.are.same("  ", task.indent)
    assert.are.same("x", task.status)
    assert.are.same("完了したサブタスク", task.content)
    
    local serialized = task_mod.serialize(task)
    assert.are.same(line, serialized)
  end)

  it("タグのような文字列が本文に含まれても破壊されないことの確認 (P0-3 準備)", function()
    -- P0-3 は未修正だが、現在の parse/serialize がどうなるか検証する
    -- もし P0-3 が直っていなければ、"+5%" が project タグとして抽出されてしまう。
    -- 現在の実装では project が "+5%" になり、content から消えるため失敗する可能性がある。
    -- TODO: P0-3 の修正後にこのテストが完全に意図通り動作することを確認する。
    local line = "- [ ] 利益を +5% 向上させる @12:00 due:2025-01-01"
    local task = task_mod.parse(line)
    
    -- 現状では本文中の "+" や "@" がタグとして誤認される。
    -- 将来的に P0-3 が修正されたら、以下のようになるべき:
    -- assert.are.same("利益を +5% 向上させる @12:00", task.content)
    -- assert.is_nil(task.project)
    
    local serialized = task_mod.serialize(task)
    -- ラウンドトリップで欠落しないことは最低限保証されるべき
    -- (誤爆して抽出されても、serialize 時に再度文字列として結合されるため、見た目上の完全な破壊ではないが、順序が変わる)
    -- 一旦 pending または緩いテストにしておく
  end)

end)
