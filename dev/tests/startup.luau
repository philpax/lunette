-- Production reload clears modules and restarts the development configuration in the same Lua state.
local testing = require '@testing'
local expect = testing.expect

local test = testing.suite()

local function live(list)
  local count = 0
  for _, handle in ipairs(list) do
    if not handle.dead then
      count += 1
    end
  end
  return count
end

test('the development configuration starts on load and survives ten production F5 reloads', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'dev'

  require 'conf'
  local configuration = { window = {}, headset = {} }
  lovr.conf(configuration)
  expect.equal(configuration.identity, 'lunette-dev', 'development saves do not share the shipped identity')
  expect.equal(configuration.saveprecedence, false, 'saved files cannot shadow development sources')
  expect.equal(configuration.headset.overlay, true, 'development retains the desktop overlay mode')
  expect.equal(configuration.window.title, 'lunette development', 'the simulator window identifies development')

  require 'main'
  expect.equal(#events.spawned + #events.claims + #events.seats + events.reads, 0, 'requiring main starts nothing')
  for name in pairs(events.subscriptions) do
    expect.equal(native.subscriptionCount(name), 0, 'a subscription before load: ' .. name)
  end
  for _, name in ipairs { 'load', 'update', 'draw', 'quit', 'keypressed', 'textinput' } do
    expect.equal(type(lovr[name]), 'function', 'the bound callback ' .. name)
  end

  lovr.load()
  expect.equal(#events.spawned, 1, 'development startup opens one demonstration terminal')
  expect.equal(events.spawned[1].argv[1], 'ghostty', 'the first default program')
  expect.equal(events.enumerations, 2, 'adoption and the demonstration terminal each enumerate once')
  expect.equal(events.reads, 1, 'the desktop reads its saved arrangement')
  expect.equal(live(events.seats), 2, 'the desktop starts both hand seats')
  expect.equal(native.subscriptionCount 'onProcessExited', 1, 'the inserted process subscription')
  lovr.load()
  expect.equal(#events.spawned, 1, 'load is idempotent')

  native.emit('onProcessExited', { process = { id = 999 }, outcome = 'spawnFailed' })
  expect.equal(#events.spawned, 1, 'an unrelated process does not trigger fallback')
  native.emit('onProcessExited', { process = events.spawned[1], outcome = 'spawnFailed' })
  expect.equal(#events.spawned, 2, 'a missing terminal advances fallback')
  expect.equal(events.spawned[2].argv[1], 'foot', 'the next default program')
  native.emit('onProcessExited', { process = events.spawned[2], outcome = 'exited', code = 0 })

  -- No window appears, so only the session-global guard prevents another startup process.
  expect.equal(#events.windows, 0, 'the compositor remains empty before source reload')
  for reload = 1, 10 do
    events.logs = {}
    lovr.keypressed('f5', 0, false)
    expect.equal(#events.logs, 0, 'reload ' .. reload .. ' failed: ' .. tostring(events.logs[1] and events.logs[1][1]))
    expect.equal(events.enumerations, reload + 2, 'reload ' .. reload .. ' enumerates only for adoption')
    expect.equal(events.reads, reload + 1, 'reload ' .. reload .. ' starts desktop persistence')
    expect.equal(#events.spawned, 2, 'reload ' .. reload .. ' starts no terminal')
    expect.equal(live(events.seats), 2, 'reload ' .. reload .. ' replaces the hand seats')
    for _, name in ipairs { 'onWindowOpened', 'onProcessExited', 'onMonitorAdded', 'onError' } do
      expect.equal(native.subscriptionCount(name), 1, 'reload ' .. reload .. ' leaves one ' .. name)
    end
    lovr.update(0.016)
    expect.equal(lovr.draw(events.pass), false, 'reload ' .. reload .. ' draws the desktop')
  end
  native.emit('onProcessExited', { process = events.spawned[2], outcome = 'spawnFailed' })
  expect.equal(#events.spawned, 2, 'the new source does not retain an old fallback attempt')

  expect.equal(lovr.quit(), false, 'quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the shutdown failures')
  native.assertResourcesReleased()
end)

return test
