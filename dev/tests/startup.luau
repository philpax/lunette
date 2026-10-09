-- The development configuration starts its demonstration terminal and survives a production source reload.
local testing = require '@testing'
local expect = testing.expect

local test = testing.suite()

test('the development configuration starts on load and survives a source reload', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'dev'

  require 'conf'
  local configuration = { window = {}, headset = {} }
  lovr.conf(configuration)
  expect.equal(configuration.identity, 'lunette-dev', 'development saves do not share the shipped identity')
  expect.equal(configuration.saveprecedence, false, 'saved files cannot shadow development sources')

  require 'main'
  lovr.load()
  expect.equal(#events.spawned, 1, 'development startup opens one demonstration terminal')
  expect.equal(events.reads, 1, 'the desktop reads its saved arrangement')

  local loaded, failure = require('@lunette').reload()
  expect.truthy(loaded, tostring(failure))
  expect.equal(#events.spawned, 1, 'the reload starts no terminal')
  for _, name in ipairs { 'onWindowOpened', 'onProcessExited', 'onMonitorAdded', 'onError' } do
    expect.equal(native.subscriptionCount(name), 1, 'the reload leaves one ' .. name)
  end
  lovr.update(0.016)
  expect.equal(lovr.draw(events.pass), false, 'the reloaded desktop draws')

  expect.equal(lovr.quit(), false, 'quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the shutdown failures')
  native.assertResourcesReleased()
end)

return test
