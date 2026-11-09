local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/fixture'
local menu = require '@lunette-contracts/menu'
local test = testing.suite()

test('menu owner registration and failure lifecycle', function()
  local env = fixture.start()
  local calls = 0
  local owned = fixture.probe(env, 'menu-owned')
  owned.service:register(
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
  expect.equal(env.service:invoke('fixture.action').kind, 'unavailable', 'a removed action')
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

test('a registration updates its state, every change is announced, and a disabled action is unavailable', function()
  local env = fixture.start()
  local other = fixture.probe(env, 'menu-other')
  local heard = 0
  env.service:onChanged(other.owner, {
    run = function()
      heard += 1
    end,
  })
  local registration = env.service:register(env.owner, fixture.action 'fixture.state')
  expect.equal(heard, 1, 'the registration is announced')
  expect.equal(registration:update { enabled = false, selected = true }, true, 'the registration updates')
  expect.equal(heard, 2, 'the update is announced')
  expect.equal(registration:update { enabled = false }, true, 'an unchanged update')
  expect.equal(heard, 2, 'an unchanged update is not announced')
  local row = env.service:list()[1]
  expect.truthy(row.enabled == false and row.selected == true, 'the updated state')
  expect.equal(env.service:invoke('fixture.state').kind, 'unavailable', 'a disabled action')
  registration:dispose()
  expect.equal(heard, 3, 'the removal is announced')
  expect.equal(registration:update { enabled = true }, false, 'a disposed registration cannot update')
  expect.equal(#env.service:list(), 0, 'an update does not recreate the action')
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
  expect.equal(env.service:invoke(row.id, row.token).kind, 'unavailable', 'the stale row is rejected')
  expect.equal(calls, 0, 'stale tokens never invoke the replacement')
  expect.equal(env.service:invoke(replacement.id, replacement.token).kind, 'invoked', 'the current row invokes')
  expect.equal(calls, 1, 'only the current invocation runs')
  env.session:close()
end)

test('lists sort by group, label, and id, and fill the defaults', function()
  local env = fixture.start()
  env.service:register(env.owner, fixture.action 'z')
  env.service:register(env.owner, { id = 'b', label = 'A', run = function() end })
  env.service:register(env.owner, { id = 'a', label = 'A', run = function() end })
  env.service:register(env.owner, { id = 'grouped', label = 'Grouped', group = 'alpha', run = function() end })
  local rows = env.service:list()
  expect.equal(rows[1].id, 'a', 'id breaks a label tie')
  expect.equal(rows[2].id, 'b', 'the second tied id')
  expect.equal(rows[3].id, 'z', 'a later label')
  expect.equal(rows[4].id, 'grouped', 'a named group follows the empty default group')
  local row = rows[3]
  expect.equal(row.group, '', 'the default group')
  expect.equal(row.enabled, true, 'the enabled default')
  expect.equal(row.selected, false, 'the selected default')
  env.session:close()
end)

test('disabled reasons disable invocation, preserve omitted state, and clear explicitly', function()
  local env = fixture.start()
  local calls, heard = 0, 0
  env.service:onChanged(env.owner, {
    run = function()
      heard += 1
    end,
  })
  local registration = env.service:register(env.owner, {
    id = 'fixture.reason',
    label = 'Reason',
    disabledReason = 'Tracking is lost.',
    run = function()
      calls += 1
    end,
  })
  local function row(): menu.Descriptor
    return env.service:list()[1]
  end
  expect.equal(row().disabledReason, 'Tracking is lost.')
  expect.equal(row().enabled, false, 'a reason alone disables the action')
  expect.equal(env.service:invoke('fixture.reason').kind, 'unavailable')
  registration:update { selected = true }
  expect.equal(row().disabledReason, 'Tracking is lost.', 'omission preserves the reason')
  registration:update { disabledReason = 'The runtime is unavailable.' }
  expect.equal(heard, 3, 'a changed reason is announced')
  registration:update { disabledReason = 'The runtime is unavailable.' }
  expect.equal(heard, 3, 'an unchanged reason is not announced')
  registration:update { enabled = false, disabledReason = false }
  expect.equal(row().disabledReason, nil, 'false clears the reason')
  expect.equal(row().enabled, false, 'clearing does not override an explicit disabled flag')
  registration:update { disabledReason = 'Waiting.', enabled = true }
  expect.equal(row().enabled, false, 'an enabled flag cannot bypass a reason')
  registration:update { disabledReason = false }
  expect.equal(row().enabled, true)
  expect.equal(env.service:invoke('fixture.reason').kind, 'invoked')
  expect.equal(calls, 1)
  env.session:close()
end)

return test
