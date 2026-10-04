local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'

local test = testing.suite()

test('start resolves a built-in plugin named by its path and enables the entries in order', function()
  local session =
    testing.start { 'tags', { id = 'panels', definition = require('@lunette-plugins/panels').definition } }
  expect.equal(session.instances.tags:state(), 'active', 'the tags provider')
  expect.equal(session.instances.panels:state(), 'active', 'the panels provider')
  session:close()
end)

test('an observed service stays current across its provider outage', function()
  local session = testing.start { 'tags' }
  local tags = session:observe(tagsContract.capability)
  local before = tags.service
  expect.truthy(before, 'the service before the outage')
  session.instances.tags:disable()
  session.instances.tags:enable()
  expect.truthy(tags.service and tags.service ~= before, 'the service after the outage')
  expect.truthy(tags.context:active(), 'the observer context after the outage')
  session:close()
end)

test('use enables a definition of the test in the session runtime', function()
  local session = testing.start { 'tags' }
  local initialized = false
  local instance = session:use(plugin.define {
    name = 'testing-use',
    requires = { tags = tagsContract.capability },
    init = function()
      initialized = true
    end,
  })
  expect.truthy(initialized, 'the initializer ran')
  expect.equal(instance:state(), 'active', 'the instance')
  session:close()
end)

test('boot binds the frame callbacks, and closing releases the claims of the session', function()
  local session = testing.boot { 'frame', 'surfaces', 'panels' }
  local native = session.native
  expect.equal(type(lovr.update), 'function', 'the bound update')
  local panels = session:observe(panelsContract.capability)
  local window = native.newWindow(1)
  panels.service:fromWindow(panels.context, window)
  expect.equal(#native.events.claims, 1, 'the claim of the window panel')
  session:update()
  expect.equal(session:draw(), false, 'draw does not veto the pass')
  session:close()
  expect.truthy(native.events.claims[1].dead, 'the claim is released with its owner')
end)

test('the fake reports a resource left behind', function()
  local native = testing.native()
  local seat = require('@lunette').newSeat 'left behind'
  expect.raises(native.assertResourcesReleased, 'leaked native seat', 'the leaked seat')
  seat:destroy()
  native.assertResourcesReleased()
end)

test('the fake delivers events to live subscriptions only', function()
  local native = testing.native()
  local heard = 0
  local cancel = require('@lunette').onWindowOpened(function()
    heard += 1
  end)
  native.emit('onWindowOpened', { window = native.newWindow(1) })
  cancel()
  native.emit('onWindowOpened', { window = native.newWindow(2) })
  expect.equal(heard, 1, 'the deliveries')
  expect.equal(native.subscriptionCount 'onWindowOpened', 0, 'the live subscriptions')
end)

return test
