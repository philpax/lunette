-- Uses the real plugin runtime and the fake native process and event APIs.
local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local adapter = require '@lunette-plugin/adapter'
local demoTerminal = require('../').definition

local test = testing.suite()

-- The fake enforces subscription-before-enumeration for the desktop's adoption path.
local windowObserver = adapter.define {
  name = 'testing/window-observer',
  init = function(context: adapter.Context)
    context:on {
      event = lunette.onWindowOpened,
      run = function() end,
    }
  end,
}

local function start(programs: { string }?): testing.Session
  return testing.start {
    { id = 'window-observer', definition = windowObserver },
    { id = 'dev/demo-terminal', definition = demoTerminal, config = { programs = programs } },
  }
end

local function fixture(programs: { string }?, occupied: boolean?): (testing.Native, testing.Session)
  _G.lunetteDemonstrationSpawned = nil
  local native = testing.native()
  if occupied then
    native.events.windows = { native.newWindow(1) }
  end
  return native, start(programs)
end

local function close(native: testing.Native, session: testing.Session)
  session:close()
  native.assertResourcesReleased()
end

test(
  'an existing window or an empty program list prevents startup, and a later reload does not launch a terminal',
  function()
    local native, session = fixture({ 'first-terminal' }, true)
    expect.equal(#native.events.spawned, 0, 'the occupied startup')
    expect.equal(native.events.enumerations, 1, 'the occupied startup enumeration')
    native.events.windows = {}
    session.instances['dev/demo-terminal']:requestReload { programs = { 'second-terminal' } }
    session.runtime:drain()
    expect.equal(#native.events.spawned, 0, 'the empty compositor after reload')
    expect.equal(native.events.enumerations, 1, 'reload does not repeat the startup enumeration')
    expect.equal(native.subscriptionCount 'onProcessExited', 1, 'reload replaces the subscription')
    close(native, session)

    native, session = fixture {}
    expect.equal(#native.events.spawned, 0, 'the disabled startup')
    expect.equal(native.events.enumerations, 0, 'a disabled startup does not enumerate windows')
    session.instances['dev/demo-terminal']:requestReload { programs = { 'first-terminal' } }
    session.runtime:drain()
    expect.equal(#native.events.spawned, 0, 'reload does not repeat the disabled startup')
    expect.equal(#native.events.logs, 0, 'an empty program list is not exhaustion')
    close(native, session)
  end
)

test('an empty compositor starts the first program, failures advance in order, and exhaustion warns once', function()
  local native, session = fixture { 'first-terminal', 'second-terminal', 'third-terminal' }
  local events = native.events
  expect.equal(#events.spawned, 1, 'the initial process count')
  expect.equal(events.spawned[1].argv[1], 'first-terminal', 'the configured first program')
  native.emit('onProcessExited', { process = { id = 999 }, outcome = 'exited' })
  expect.equal(#events.spawned, 1, 'an unrelated exit does not advance')
  native.emit('onProcessExited', { process = events.spawned[1], outcome = 'spawnFailed' })
  expect.equal(#events.spawned, 2, 'the first fallback')
  expect.equal(events.spawned[2].argv[1], 'second-terminal', 'the second configured program')
  native.emit('onProcessExited', { process = events.spawned[1], outcome = 'spawnFailed' })
  expect.equal(#events.spawned, 2, 'an old failure does not skip a program')
  native.emit('onProcessExited', { process = events.spawned[2], outcome = 'spawnFailed' })
  expect.equal(events.spawned[3].argv[1], 'third-terminal', 'the third configured program')
  expect.equal(#events.logs, 0, 'no warning before exhaustion')
  native.emit('onProcessExited', { process = events.spawned[3], outcome = 'spawnFailed' })
  expect.equal(#events.spawned, 3, 'exhaustion starts no further process')
  expect.equal(#events.logs, 1, 'the exhaustion warning count')
  expect.equal(
    events.logs[1][1],
    'no terminal emulator was found; start a client with WAYLAND_DISPLAY',
    'the exhaustion guidance'
  )
  expect.equal(events.logs[1][2], 'warn', 'the exhaustion log level')
  expect.equal(events.logs[1][3], 'lunette.desktop', 'the exhaustion log tag')
  native.emit('onProcessExited', { process = events.spawned[3], outcome = 'spawnFailed' })
  expect.equal(#events.logs, 1, 'a repeated exit does not warn again')
  close(native, session)

  native, session = fixture()
  expect.equal(native.events.spawned[1].argv[1], 'ghostty', 'the first default program')
  close(native, session)
end)

return test
