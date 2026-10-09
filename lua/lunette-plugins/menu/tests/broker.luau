local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/fixture'
local test = testing.suite()

test('menu owner registration and failure lifecycle', function()
  local env = fixture.start()
  local calls = 0
  local owned = fixture.probe(env, 'menu-owned')
  local effect = owned.service:register(
    owned.owner,
    fixture.action('fixture.action', function()
      calls += 1
    end)
  )
  expect.equal(env.service:invoke('fixture.action').kind, 'invoked', 'a live action')
  expect.equal(calls, 1, 'the callback runs once')
  expect.raises(function()
    env.service:register(env.owner, fixture.action 'fixture.action')
  end, 'menu register: fixture.action is already registered', 'a globally duplicate id')
  owned.instance:disable()
  expect.equal(#env.service:list(), 0, 'owner removal removes the registration')
  expect.equal(env.service:update(owned.owner, effect, { enabled = true }), false, 'an ended owner cannot update')
  expect.equal(env.service:invoke('fixture.action').kind, 'unavailable', 'a removed action')
  expect.raises(function()
    env.service:register(owned.owner, fixture.action 'late')
  end, 'plugin', 'late registration has no owner authority')
  env.service:register(
    env.owner,
    fixture.action('fixture.action', function()
      error 'the menu callback raises'
    end)
  )
  local result = env.service:invoke 'fixture.action'
  expect.equal(result.kind, 'failed', 'a failure is explicit')
  expect.truthy(type(result.message) == 'string' and #result.message > 0, 'the result has a failure message')
  local reports = env.native.events.reported
  expect.equal(#reports, 1, 'one callback failure report')
  testing.takeReports()
  expect.truthy(reports[1].message:find('the menu callback raises', 1, true), reports[1].message)
  expect.equal(#env.service:inspect().registrations, 1, 'failure does not dispose the registration')
  env.session:close()
end)

test('updates require the actual registering owner and effect and never create a registration', function()
  local env = fixture.start()
  local other = fixture.probe(env, 'menu-other')
  local effect = env.service:register(env.owner, fixture.action 'fixture.state')
  local foreignEffect = env.owner:effect(function()
    return function() end
  end)
  expect.equal(env.service:update(other.owner, effect, { enabled = false }), false, 'another dependent cannot update')
  expect.equal(env.service:update(env.owner, foreignEffect, { enabled = false }), false, 'an unrelated effect')
  local state = { enabled = false, selected = true }
  expect.equal(env.service:update(env.owner, effect, state), true, 'the registering owner updates')
  state.enabled, state.selected = true, false
  local row = env.service:list()[1]
  expect.equal(row.enabled, false, 'enabled is copied')
  expect.equal(row.selected, true, 'selected is copied')
  expect.equal(env.service:invoke('fixture.state').kind, 'unavailable', 'a disabled action')
  expect.equal(env.service:update(env.owner, effect, {}), true, 'an empty update is a no-op')
  expect.equal(env.service:list()[1].enabled, false, 'omitted state preserves enabled')
  expect.equal(env.service:update(env.owner, effect, { enabled = true }), true, 'enabled changes independently')
  expect.equal(env.service:list()[1].selected, true, 'omitted state preserves selected')
  effect:dispose()
  expect.equal(env.service:update(env.owner, effect, { enabled = true }), false, 'a disposed effect cannot update')
  expect.equal(#env.service:list(), 0, 'an update does not recreate the action')
  env.service:register(env.owner, fixture.action 'fixture.state')
  expect.equal(
    env.service:update(env.owner, effect, { enabled = false }),
    false,
    'an old effect cannot update its replacement'
  )
  expect.equal(env.service:list()[1].enabled, true, 'the replacement keeps its own state')
  env.session:close()
end)

test('a list token rejects a removed registration even after its id is reused', function()
  local env = fixture.start()
  local calls = 0
  local first = env.service:register(env.owner, fixture.action 'fixture.reused')
  local row = env.service:list()[1]
  first:dispose()
  env.service:register(
    env.owner,
    fixture.action('fixture.reused', function()
      calls += 1
    end)
  )
  local replacement = env.service:list()[1]
  expect.truthy(row.registration ~= replacement.registration, 'a replacement has a fresh token')
  expect.equal(env.service:invoke(row.id, row.registration).kind, 'unavailable', 'the stale row is rejected')
  expect.equal(calls, 0, 'stale tokens never invoke the replacement')
  expect.equal(env.service:invoke(replacement.id, replacement.registration).kind, 'invoked', 'the current row invokes')
  expect.equal(env.service:invoke(row.id).kind, 'invoked', 'id-only invocation retains its narrow shape')
  expect.equal(calls, 2, 'only current invocations run')
  env.session:close()
end)
test('lists sort by group, order, and id, and fill the defaults', function()
  local env = fixture.start()
  env.service:register(env.owner, fixture.action 'z')
  env.service:register(env.owner, { id = 'b', label = 'B', order = -1, run = function() end })
  env.service:register(env.owner, { id = 'a', label = 'A', order = -1, run = function() end })
  env.service:register(env.owner, { id = 'grouped', label = 'Grouped', group = 'alpha', run = function() end })
  local rows = env.service:list()
  expect.equal(rows[1].id, 'a', 'id breaks an order tie')
  expect.equal(rows[2].id, 'b', 'the second tied id')
  expect.equal(rows[3].id, 'z', 'ungrouped order')
  expect.equal(rows[4].id, 'grouped', 'a named group follows the empty default group')
  local row = rows[3]
  expect.equal(row.group, '', 'the default group')
  expect.equal(row.order, 0, 'the default order')
  expect.equal(row.enabled, true, 'the enabled default')
  expect.equal(row.selected, false, 'the selected default')
  env.session:close()
end)

return test
