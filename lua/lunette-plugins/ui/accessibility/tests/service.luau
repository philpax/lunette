local testing = require '@testing'
local accessibility = require '@lunette-contracts/accessibility'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

test('partial updates keep other settings, and a rejected batch publishes nothing', function()
  local state = fixture.boot {
    plugins = { require('@lunette-plugins/ui/accessibility').definition },
  }
  local observed = assert(state.fixture.session):observe(accessibility.capability)
  local service = assert(observed.service)
  service:update { timing = 2, sounds = false }
  service:update { textScale = 1.5 }
  local current = service.settings:get()
  expect.equal(current.timing, 2, 'a later update keeps the earlier timing')
  expect.equal(current.sounds, false, 'and sounds')
  expect.equal(current.textScale, 1.5, 'while applying the new scale')
  local changes = 0
  local unsubscribe = service.settings:subscribe(function()
    changes += 1
  end)
  expect.raises(function()
    service:update { timing = 3, textScale = 9 }
  end, 'not a valid textScale')
  expect.equal(service.settings:get(), current, 'a rejected batch keeps the same immutable settings')
  expect.equal(changes, 0, 'and publishes no change')
  unsubscribe()
  state.fixture:close()
end)

test('announcement delivery skips a listener disposed during the same announcement', function()
  local state = fixture.boot {
    plugins = { require('@lunette-plugins/ui/accessibility').definition },
  }
  local observed = assert(state.fixture.session):observe(accessibility.capability)
  local service, owner = assert(observed.service), assert(observed.context)
  local heard: { string } = {}
  local pending
  service:onAnnouncement(owner, {
    run = function()
      table.insert(heard, 'first')
      pending:dispose()
    end,
  })
  pending = service:onAnnouncement(owner, {
    run = function()
      table.insert(heard, 'disposed')
    end,
  })
  service:announce(owner, { text = 'ready', politeness = 'polite' })
  expect.equal(table.concat(heard, ','), 'first', 'a disposed registration no longer receives announcements')
  state.fixture:close()
end)

test('announcement errors are reported without stopping delivery, and ended owners receive nothing', function()
  local state = fixture.boot {
    plugins = { require('@lunette-plugins/ui/accessibility').definition },
  }
  local observed = assert(state.fixture.session):observe(accessibility.capability)
  local service, owner = assert(observed.service), assert(observed.context)
  local heard = 0
  service:onAnnouncement(owner, {
    run = function()
      error('announcement failed', 0)
    end,
  })
  service:onAnnouncement(owner, {
    run = function()
      heard += 1
    end,
  })
  service:announce(owner, { text = 'ready', politeness = 'polite' })
  expect.equal(heard, 1, 'a raising listener does not stop later listeners')
  expect.equal(#state.fixture.native.events.reported, 1, 'the failure is reported')
  expect.truthy(state.fixture.native.events.reported[1].message:find('announcement failed', 1, true))
  assert(observed.instance):disable()
  local another = assert(state.fixture.session):observe(accessibility.capability)
  service:announce(assert(another.context), { text = 'again', politeness = 'polite' })
  expect.equal(heard, 1, 'the ended owner receives no later announcement')
  state.fixture:close()
end)

return test
