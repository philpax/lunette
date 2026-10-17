-- The shipped configuration reloads from controller menu input and releases each previous resource generation.
local testing = require '@testing'
local expect = testing.expect
local vrUi = require '@testing/vr-ui'
local wristMenu = require '@testing/wrist-menu'

local test = testing.suite()

local function live(list: { read [number]: { read dead: boolean } }): number
  local count = 0
  for _, handle in ipairs(list) do
    if not handle.dead then
      count += 1
    end
  end
  return count
end

test('the shipped configuration starts on load and survives ten production reloads', function()
  local native = testing.native()
  local events, emit, newWindow = native.events, native.emit, native.newWindow
  local hands = vrUi.hands(native)
  testing.host.useConfiguration 'etc/xdg/lunette'

  -- The configuration's definitions are inert until LÖVR loads it.
  require 'main'
  expect.equal(#events.spawned + #events.claims + #events.seats + events.reads, 0, 'requiring main starts nothing')
  for name in pairs(events.subscriptions) do
    expect.equal(native.subscriptionCount(name), 0, 'a subscription before load: ' .. name)
  end
  for _, name in ipairs { 'load', 'update', 'draw', 'quit', 'keypressed', 'textinput' } do
    expect.equal(type(lovr[name]), 'function', 'the bound callback ' .. name)
  end

  lovr.load()
  expect.equal(events.reads, 1, 'the saved arrangement is read once')
  events.windows = { newWindow(1), newWindow(2, 'firefox') }
  for _, window in ipairs(events.windows) do
    emit('onWindowOpened', { window = window })
  end
  lovr.update(0.016)
  expect.equal(lovr.draw(events.pass), false, 'draw does not submit or veto the pass')
  expect.equal(events.textures, 2, 'each window draws')

  -- The right beam presses the panel in front, which focuses it, and text reaches it.
  hands:button('right', 'trigger', true)
  lovr.update(0.016)
  hands:button('right', 'trigger', false)
  lovr.update(0.016)
  local before = #events.input
  lovr.textinput('q', 0)
  expect.truthy(#events.input > before, 'text reaches the focused window')

  local startupProcesses = #events.spawned
  testing.host.useConfiguration 'lua/lunette-desktop/tests/support/vr-reload'
  local loaded, failure = require('@lunette').reload()
  expect.truthy(loaded, tostring(failure))
  local fixture = vrUi.attach(native)
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  for reload = 1, 10 do
    local controls = assert(_G.vrReloadControls, 'the composition observer is active')
    local currentHost, panels = controls.host, controls.panels
    fixture:step()
    wristMenu.open(fixture, panels)
    events.logs = {}
    panels:click(fixture, wristMenu.PANEL, wristMenu.row 'desktop/reload')
    expect.falsy(
      pcall(function(): typeof(require('@lunette-contracts/inspection').snapshot {})
        return currentHost:inspect()
      end),
      'reload withdraws the previous UI generation'
    )
    expect.equal(#events.logs, 0, 'reload ' .. reload .. ' failed: ' .. tostring(events.logs[1] and events.logs[1][1]))
    expect.equal(#events.spawned, startupProcesses, 'reload ' .. reload .. ' spawns nothing')
    expect.truthy(events.closed == 0 and live(events.windows) == 2, 'reload ' .. reload .. ' closes no window')
    -- The error stream and the recovery plugin each subscribe to native errors.
    for name, count in { onWindowOpened = 1, onMonitorAdded = 1, onError = 2 } do
      expect.equal(
        native.subscriptionCount(name),
        count,
        'reload ' .. reload .. ' leaves the expected ' .. name .. ' subscriptions'
      )
    end
    expect.equal(live(events.seats), 2, 'reload ' .. reload .. ' releases the previous seats')
    lovr.update(0.016)
    expect.equal(lovr.draw(events.pass), false, 'reload ' .. reload .. ' draws')
  end

  -- After the reloads the right beam still presses the panel in front, and text reaches it.
  fixture:pose('left', lovr.math.newMat4():translate(-5, 1.5, 0))
  fixture:pose('right', lovr.math.newMat4():translate(0, 1.5, 0))
  fixture:step()
  fixture:button('right', 'trigger', true)
  fixture:step()
  fixture:button('right', 'trigger', false)
  fixture:step()
  local right = nil
  for _, seat in ipairs(events.seats) do
    if not seat.dead and seat.name == 'laser.right' then
      right = seat
    end
  end
  assert(right, 'the right laser holds a live seat after the reloads')
  expect.equal(right.focus, events.windows[1].sink, 'the right laser focuses the window in front after the reloads')
  local typed = #events.input
  lovr.textinput('q', 0)
  local reached = false
  for index = typed + 1, #events.input do
    local call = events.input[index]
    if call[#call] == right then
      reached = true
    end
  end
  expect.truthy(reached, 'text reaches the focused window through the right seat after the reloads')

  expect.equal(lovr.quit(), false, 'quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  native.assertResourcesReleased()
end)

return test
