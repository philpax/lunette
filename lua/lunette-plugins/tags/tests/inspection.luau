local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/tags'
local test = testing.suite()

local function count(snapshot, kind)
  local total = 0
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind then
      total += 1
    end
  end
  return total
end

local function registration(snapshot, kind, sourceId)
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind and (sourceId == nil or entry.details.sourceId == sourceId) then
      return entry
    end
  end
  error('missing ' .. kind .. ' registration')
end

local function expectFrozen(snapshot)
  expect.equal(table.isfrozen(snapshot), true, 'the frozen snapshot')
  expect.equal(table.isfrozen(snapshot.registrations), true, 'the frozen registration list')
  expect.equal(table.isfrozen(snapshot.state), true, 'the frozen state')
  expect.equal(table.isfrozen(snapshot.unobservable), true, 'the frozen unavailable facts')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(table.isfrozen(entry), true, 'the frozen registration')
    expect.equal(table.isfrozen(entry.details), true, 'the frozen registration details')
  end
end

test('inspection leaves private target liveness unavailable and logical entries unchanged', function()
  local session = testing.start { 'tags' }
  local observer = session:observe(contract.capability)
  local service = observer.service
  local tag, hold = service:hold(observer.context, { name = 'fixture.private' })
  local privateDead, inspecting, getterCalls = false, false, 0
  local target = setmetatable({}, {
    __index = function(_, key)
      if inspecting then
        getterCalls += 1
      end
      if key == 'dead' then
        return privateDead
      end
      return nil
    end,
  })
  tag:add(observer.context, target)
  local excluded = tag:exclude(observer.context, { panel = target })
  local changes = 0
  local listener = service:onChanged(observer.context, {
    run = function()
      changes += 1
    end,
  })
  inspecting = true
  local before = service:inspect()
  inspecting = false
  privateDead = true
  inspecting = true
  local snapshot = service:inspect()
  inspecting = false
  expect.equal(rawget(target, 'dead'), nil, 'the death state remains private')
  expect.equal(getterCalls, 0, 'inspection never invokes a getter')
  expect.equal(changes, 0, 'inspection never notifies listeners')
  expect.equal(#snapshot.registrations, #before.registrations, 'unchanged logical entries')
  for _, kind in ipairs { 'membership', 'exclusion' } do
    expect.equal(count(snapshot, kind), 1, 'the retained ' .. kind)
    local entry, initial = registration(snapshot, kind), registration(before, kind)
    expect.equal(entry.details.targetLiveness, 'unavailable', 'the unobserved target liveness')
    expect.equal(initial.details.targetLiveness, 'unavailable', 'the initially unobserved target liveness')
    expect.equal(entry.live, true, 'the logical entry remains live')
    expect.equal(entry.owner, initial.owner, 'the retained owner')
    expect.equal(entry.name, initial.name, 'the retained tag name')
    expect.equal(entry.source, if kind == 'membership' then 'tags.add' else 'tags.exclude', 'the entry source')
  end
  expect.equal(registration(snapshot, 'membership').details.excluded, true, 'the retained exclusion state')
  listener:dispose()
  tag:panels()
  expect.equal(count(service:inspect(), 'membership'), 0, 'normal pruning ends the private dead membership')
  expect.equal(count(service:inspect(), 'exclusion'), 0, 'normal pruning ends the private dead exclusion')
  excluded:dispose()
  hold:dispose()
  expect.equal(#service:inspect().registrations, 0, 'all effects end normally')
  expect.equal(count(snapshot, 'membership'), 1, 'the detached membership after disposal')
  expect.equal(
    registration(snapshot, 'membership').details.targetLiveness,
    'unavailable',
    'the retained unavailable fact'
  )
  expectFrozen(snapshot)
  session:close()
end)

test('inspection retains discriminated window and monitor source IDs for memberships and exclusions', function()
  local session = testing.start { 'tags' }
  local observer = session:observe(contract.capability)
  local service = observer.service
  local tag, hold = service:hold(observer.context, { name = 'fixture.sources' })
  local fixtures = {
    { kind = 'monitor', id = 'fixture.monitor' },
    { kind = 'window', id = 22 },
  }
  local excluded = {}
  for _, fixture in ipairs(fixtures) do
    local source = setmetatable({ id = fixture.id }, {
      __index = function()
        error 'inspection invoked a source getter'
      end,
    })
    local target = setmetatable({ dead = false, kind = fixture.kind, source = source }, {
      __index = function()
        error 'inspection invoked a surface getter'
      end,
    })
    tag:add(observer.context, target)
    excluded[#excluded + 1] = tag:exclude(observer.context, { panel = target })
  end
  local snapshot = service:inspect()
  expect.equal(count(snapshot, 'membership'), 2, 'the source memberships')
  expect.equal(count(snapshot, 'exclusion'), 2, 'the source exclusions')
  for _, fixture in ipairs(fixtures) do
    for _, kind in ipairs { 'membership', 'exclusion' } do
      local entry = registration(snapshot, kind, fixture.id)
      expect.equal(entry.source, if kind == 'membership' then 'tags.add' else 'tags.exclude', 'the entry source')
      expect.equal(entry.details.sourceKind, fixture.kind, 'the source kind')
      expect.equal(entry.details.sourceId, fixture.id, 'the source ID')
      expect.equal(entry.details.targetLiveness, 'live', 'the observed target liveness')
      expect.equal(entry.live, true, 'the live logical entry')
    end
  end
  for _, effect in ipairs(excluded) do
    effect:dispose()
  end
  hold:dispose()
  expect.equal(#service:inspect().registrations, 0, 'the disposed entries')
  expect.equal(#snapshot.registrations, 5, 'the detached entry count')
  for _, fixture in ipairs(fixtures) do
    for _, kind in ipairs { 'membership', 'exclusion' } do
      local entry = registration(snapshot, kind, fixture.id)
      expect.equal(entry.details.sourceKind, fixture.kind, 'the detached source kind')
      expect.equal(entry.details.sourceId, fixture.id, 'the detached source ID')
      expect.equal(entry.live, true, 'the retained entry status')
    end
  end
  expectFrozen(snapshot)
  expect.raises(function()
    registration(snapshot, 'membership', 'fixture.monitor').details.sourceId = 'changed'
  end, 'readonly', 'source metadata stays frozen after disposal')
  session:close()
end)

test('inspection keeps tag holders and memberships separate and never prunes dead members', function()
  local session = testing.start { 'tags' }
  local first, second = session:observe(contract.capability), session:observe(contract.capability)
  local service = first.service
  local tag, hold = service:hold(first.context, { name = 'fixture.tag' })
  local same, again = service:hold(first.context, { name = 'fixture.tag' })
  expect.equal(same, tag, 'the same held tag')
  expect.equal(again, hold, 'the same owner hold')
  local _, otherHold = service:hold(second.context, { name = 'fixture.tag' })
  local target = setmetatable({ dead = false }, {
    __index = function()
      error 'inspection invoked a surface getter'
    end,
  })
  tag:add(first.context, target)
  expect.equal(tag:add(first.context, target), false, 'an inert duplicate membership')
  tag:add(second.context, target)
  local excluded = tag:exclude(second.context, { panel = target })
  tag:setSelected(first.context, { selected = true })
  tag:setSelected(first.context, { selected = false })
  tag:setLayout(second.context, { layout = 'fixture.layout' })
  local snapshot = service:inspect()
  expect.equal(count(snapshot, 'hold'), 2, 'the owner ref count')
  expect.equal(count(snapshot, 'membership'), 2, 'the membership ref count')
  expect.equal(count(snapshot, 'selection'), 1, 'a reused selection override')
  expect.equal(count(snapshot, 'layoutChoice'), 1, 'the layout override')
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == 'membership' or entry.kind == 'exclusion' then
      expect.equal(entry.details.targetLiveness, 'live', 'the initially observed live target')
    end
  end
  target.dead = true
  local listener = service:onChanged(first.context, {
    run = function()
      error 'inspection pruned a member'
    end,
  })
  local dead = service:inspect()
  expect.equal(count(dead, 'membership'), 2, 'dead members stay registered until normal pruning')
  expect.equal(count(dead, 'exclusion'), 1, 'dead exclusions stay registered until normal pruning')
  for _, entry in ipairs(dead.registrations) do
    if entry.kind == 'membership' or entry.kind == 'exclusion' then
      expect.equal(entry.live, true, 'the logical entry remains live')
      expect.equal(entry.details.targetLiveness, 'dead', 'the observed dead target')
      expect.equal(entry.source, if entry.kind == 'membership' then 'tags.add' else 'tags.exclude', 'the entry source')
    end
  end
  listener:dispose()
  excluded:dispose()
  tag:panels()
  expect.equal(count(service:inspect(), 'membership'), 0, 'normal membership cleanup')
  otherHold:dispose()
  hold:dispose()
  expect.equal(#service:inspect().registrations, 0, 'the tag and overrides end at the last hold')
  expect.equal(count(snapshot, 'membership'), 2, 'the detached initial memberships')
  expect.equal(
    registration(snapshot, 'membership').details.targetLiveness,
    'live',
    'the detached initial target liveness'
  )
  expect.equal(registration(dead, 'membership').details.targetLiveness, 'dead', 'the detached observed target death')
  expectFrozen(snapshot)
  expectFrozen(dead)
  session:close()
end)

return test
