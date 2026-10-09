local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/fixture'
local test = testing.suite()

local function callbackFree(value)
  expect.truthy(table.isfrozen(value), 'each snapshot table is frozen')
  for _, member in pairs(value) do
    expect.truthy(type(member) ~= 'function', 'a snapshot contains no callback')
    if type(member) == 'table' then
      callbackFree(member)
    end
  end
end

test('lists are copied callback-free frozen descriptors sorted by group order and id', function()
  local env = fixture.start()
  expect.equal(#env.service:list(), 0, 'an empty list')
  local calls = 0
  local action = fixture.action('z', function()
    calls += 1
  end)
  env.service:register(env.owner, action)
  action.id, action.label, action.group, action.order = 'mutated', 'Mutated', 'last', 99
  action.enabled, action.selected = false, true
  action.run = function()
    error 'a replaced callback runs'
  end
  env.service:register(env.owner, { id = 'b', label = 'B', order = -1, run = function() end })
  env.service:register(env.owner, { id = 'a', label = 'A', order = -1, run = function() end })
  env.service:register(env.owner, { id = 'grouped', label = 'Grouped', group = 'alpha', run = function() end })
  local first, second = env.service:list(), env.service:list()
  callbackFree(first)
  expect.truthy(first ~= second and first[1] ~= second[1], 'each call copies the list and descriptors')
  expect.equal(first[1].id, 'a', 'id breaks an order tie')
  expect.equal(first[2].id, 'b', 'the second tied id')
  expect.equal(first[3].id, 'z', 'ungrouped order')
  expect.equal(first[4].id, 'grouped', 'a named group follows the empty default group')
  local row = first[3]
  expect.equal(row.label, 'Action z', 'the label is captured')
  expect.equal(row.group, '', 'the default group')
  expect.equal(row.order, 0, 'the default order')
  expect.equal(row.enabled, true, 'the enabled default')
  expect.equal(row.selected, false, 'the selected default')
  expect.equal(row.registration.kind, 'menu-registration', 'a neutral identity token')
  expect.equal(row.registration, second[3].registration, 'the token is stable for its registration')
  expect.equal(env.service:invoke(row.id, row.registration).kind, 'invoked', 'the snapshotted callback invokes')
  expect.equal(calls, 1, 'mutation does not replace the callback')
  expect.raises(function()
    first[1].label = 'Changed'
  end, 'readonly', 'a descriptor cannot mutate')
  env.session:close()
end)

test('inspection captures owner counts and state without invoking callbacks', function()
  local env = fixture.start()
  local owned = fixture.probe(env, 'menu-inspected')
  local effect = owned.service:register(owned.owner, {
    id = 'fixture.inspected',
    label = 'Inspected',
    group = 'tools',
    order = 3,
    enabled = false,
    selected = true,
    run = function()
      error 'inspection calls an action'
    end,
  })
  local snapshot = env.service:inspect()
  expect.truthy(table.isfrozen(snapshot) and table.isfrozen(snapshot.registrations), 'inspection is frozen')
  expect.equal(#snapshot.registrations, 1, 'one logical registration')
  local entry = snapshot.registrations[1]
  expect.equal(entry.owner, owned.owner, 'the actual registering owner')
  expect.equal(entry.kind, 'handler', 'the shared inspection kind')
  expect.equal(entry.source, 'menu.register', 'the registration source')
  expect.equal(entry.name, 'fixture.inspected', 'the id')
  expect.equal(entry.details.label, 'Inspected', 'the label')
  expect.equal(entry.details.group, 'tools', 'the group')
  expect.equal(entry.details.order, 3, 'the order')
  expect.equal(entry.details.enabled, false, 'the enabled state')
  expect.equal(entry.details.selected, true, 'the selected state')
  expect.equal(#testing.takeReports(), 0, 'inspection reports no callbacks')
  effect:dispose()
  expect.equal(#env.service:inspect().registrations, 0, 'disposal forgets the registration')
  expect.equal(#snapshot.registrations, 1, 'an earlier snapshot is stable')
  env.session:close()
end)

return test
