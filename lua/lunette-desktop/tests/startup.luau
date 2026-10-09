-- The shipped configuration reloads from controller menu input and releases each previous resource generation.
local testing = require '@testing'
local expect = testing.expect
local vrUi = require '@testing/vr-ui'

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
    local currentUi = controls.ui
    fixture:step()
    local retainedPanel = currentUi:panels()[1]
    fixture:clickControl(currentUi, 'desktop/menu', 'open')
    events.logs = {}
    fixture:clickControl(currentUi, 'desktop/menu', 'actions', 'right', 'desktop/reload')
    expect.truthy(retainedPanel.dead, 'reload withdraws the previous UI generation')
    expect.equal(#events.logs, 0, 'reload ' .. reload .. ' failed: ' .. tostring(events.logs[1] and events.logs[1][1]))
    expect.equal(#events.spawned, startupProcesses, 'reload ' .. reload .. ' spawns nothing')
    expect.truthy(events.closed == 0 and live(events.windows) == 2, 'reload ' .. reload .. ' closes no window')
    for _, name in ipairs { 'onWindowOpened', 'onMonitorAdded', 'onError' } do
      expect.equal(native.subscriptionCount(name), 1, 'reload ' .. reload .. ' leaves one ' .. name)
    end
    expect.equal(live(events.seats), 2, 'reload ' .. reload .. ' releases the previous seats')
    lovr.update(0.016)
    expect.equal(lovr.draw(events.pass), false, 'reload ' .. reload .. ' draws')
  end

  expect.equal(lovr.quit(), false, 'quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  native.assertResourcesReleased()
end)

return test
