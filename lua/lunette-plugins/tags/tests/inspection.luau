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

local function registration(snapshot, kind)
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind then
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

test('inspection invokes no target getter and leaves logical entries unchanged', function()
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
  expectFrozen(snapshot)
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
  expectFrozen(snapshot)
  expectFrozen(dead)
  session:close()
end)

return test
