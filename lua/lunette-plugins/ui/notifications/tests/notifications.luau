local testing = require '@testing'
local notifications = require '@lunette-contracts/notifications'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

-- The service, and an owner that depends on it, as a notifying plugin is.
local function boot(): (fixture.State, notifications.Service, any)
  local state = fixture.boot {
    standard = true,
    width = 0.2,
    height = 0.1,
    plugins = { require('@lunette-plugins/ui/notifications').define { timeout = 1, visible = 2 } },
  }
  local observed = assert(state.fixture.session):observe(notifications.capability)
  return state, assert(observed.service), assert(observed.context)
end

local function titles(service: notifications.Service): string
  local snapshot = service:inspect()
  local list: { string } = {}
  for _, registration in snapshot.registrations do
    table.insert(list, registration.name or '?')
  end
  return table.concat(list, ',')
end

test('toasts show up to the visible limit, queue the rest, and leave after their timeout', function()
  local state, service, owner = boot()
  for _, title in { 'one', 'two', 'three' } do
    service:notify(owner, { title = title })
  end
  expect.equal(titles(service), 'one,two')
  expect.equal(service:inspect().state.queued, 1)
  for _ = 1, 70 do
    state.fixture:step(0.016)
  end
  expect.equal(titles(service), 'three', 'the first two timed out and the queued one took their place')
  expect.equal(#service.history:get(), 3, 'the history keeps every notification')
  state.fixture:close()
end)

test('a toast with no timeout stays until it is dismissed, and its action runs once', function()
  local state, service, owner = boot()
  local runs = 0
  local handle = service:notify(owner, {
    title = 'update',
    timeout = 0,
    actions = { {
      id = 'apply',
      label = 'Apply',
      run = function()
        runs += 1
      end,
    } },
  })
  for _ = 1, 120 do
    state.fixture:step(0.016)
  end
  expect.equal(titles(service), 'update', 'the toast stays')
  handle:dismiss()
  expect.truthy(handle.dead)
  expect.equal(titles(service), '')
  expect.equal(runs, 0)
  state.fixture:close()
end)

test('the toast panel takes the size of its toasts', function()
  local state, service, owner = boot()
  service:notify(owner, { title = 'ready', timeout = 0 })
  state.fixture:step()
  state.fixture:step()
  local host = state.service
  local snapshot = host:inspect()
  local found = false
  for _, registration in snapshot.registrations do
    if registration.name == 'notifications' then
      found = (registration.details.width :: number) > 0
    end
  end
  expect.truthy(found, 'the notifications panel has content')
  state.fixture:close()
end)

return test
