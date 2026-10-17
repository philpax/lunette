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

test('the accessibility timing lengthens toasts, and each notification is announced', function()
  local accessibility = require '@lunette-contracts/accessibility'
  local state = fixture.boot {
    standard = true,
    width = 0.2,
    height = 0.1,
    plugins = {
      require('@lunette-plugins/ui/accessibility').definition,
      require('@lunette-plugins/ui/notifications').define { timeout = 1, visible = 2 },
    },
  }
  local session = assert(state.fixture.session)
  local observed = session:observe(notifications.capability)
  local service, owner = assert(observed.service), assert(observed.context)
  local assist = session:observe(accessibility.capability)
  local heard: { accessibility.Announcement } = {}
  assert(assist.service):onAnnouncement(assert(assist.context), {
    run = function(announcement: accessibility.Announcement)
      table.insert(heard, announcement)
    end,
  })
  assert(assist.service):update { timing = 2 }
  service:notify(owner, { title = 'saved', body = 'The layout is saved.' })
  service:notify(owner, { title = 'failed', level = 'error' })
  expect.equal(#heard, 2, 'both notifications are announced')
  expect.equal(heard[1].text, 'saved. The layout is saved.', 'the announcement reads the title and body')
  expect.equal(heard[1].politeness, 'polite')
  expect.equal(heard[2].politeness, 'assertive', 'an error interrupts')
  for _ = 1, 70 do
    state.fixture:step(0.016)
  end
  expect.equal(titles(service), 'saved,failed', 'the doubled timing keeps the toasts past one second')
  for _ = 1, 70 do
    state.fixture:step(0.016)
  end
  expect.equal(titles(service), '', 'the toasts leave after two seconds')
  state.fixture:close()
end)

test('optional accessibility can appear, disappear, and be replaced while notifications keep running', function()
  local accessibility = require '@lunette-contracts/accessibility'
  local definition = require('@lunette-plugins/ui/accessibility').definition
  local state, service, owner = boot()
  local session = assert(state.fixture.session)
  service:notify(owner, { title = 'without accessibility', timeout = 0 }):dismiss()
  local heard: { string } = {}
  local function listen()
    local assist = session:observe(accessibility.capability)
    assert(assist.service):onAnnouncement(assert(assist.context), {
      run = function(announcement: accessibility.Announcement)
        table.insert(heard, announcement.text)
      end,
    })
  end
  local source = session:use(definition)
  listen()
  service:notify(owner, { title = 'first', timeout = 0 }):dismiss()
  expect.equal(table.concat(heard, ','), 'first', 'a later accessibility provider receives announcements')
  source:disable()
  service:notify(owner, { title = 'during outage', timeout = 0 }):dismiss()
  expect.equal(#heard, 1, 'no ended provider or listener is called')
  source:dispose()
  session:use(definition)
  listen()
  service:notify(owner, { title = 'replacement', timeout = 0 }):dismiss()
  expect.equal(table.concat(heard, ','), 'first,replacement', 'the replacement gets its own dependent owner')
  expect.equal(#service.history:get(), 4, 'notifications remain available throughout the outage')
  state.fixture:close()
end)

test('an anchored toast sits beside its panel and returns ahead of the head when the panel ends', function()
  local state, service, owner = boot()
  service:notify(owner, { title = 'beside', timeout = 0, anchor = state.panel })
  state.fixture:step()
  state.fixture:step()
  local toast = assert(state.service:find 'notifications 1:1/face', 'the toast is on a panel of its own')
  local anchorWidth = state.panel:size()
  local inverse = lovr.math.mat4(state.panel:pose()):invert()
  local x, _, z = vector.unpack(inverse:mul(vector.pack(toast:pose():getPosition())))
  expect.truthy(x > anchorWidth / 2, `the toast is right of the panel's edge: {x}`)
  expect.truthy(z > 0, 'the toast stands in front of the panel')

  state.panel:destroy()
  state.fixture:step()
  state.fixture:step()
  expect.equal(state.service:find 'notifications 1:1/face', nil, 'the anchored panel ends')
  expect.truthy(state.service:find 'notifications:1/face', 'the toast moved to the panel ahead of the head')
  state.fixture:close()
end)

return test
