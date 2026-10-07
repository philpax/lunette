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
  expect.equal(#events.spawned, 0, 'the shipped configuration opens no application')
  expect.equal(events.enumerations, 1, 'adoption enumerates once')
  expect.equal(native.subscriptionCount 'onProcessExited', 0, 'no demonstration process listener is installed')
  expect.equal(events.reads, 1, 'the saved arrangement is read once')
  lovr.load()
  expect.equal(#events.spawned, 0, 'load is idempotent')

  events.windows = { newWindow(1), newWindow(2, 'firefox') }
  for _, window in ipairs(events.windows) do
    emit('onWindowOpened', { window = window })
  end
  lovr.update(0.016)
  expect.equal(lovr.draw(events.pass), false, 'draw does not submit or veto the pass')
  expect.equal(#events.seats, 2, 'each hand owns its own seat')
  expect.equal(#events.claims, 2, 'one panel claim per live window')
  expect.equal(events.textures, 2, 'each window texture is fetched for the frame')
  local wrist, beams, firstBeam = 0, 0, 0
  for index, call in ipairs(events.draw) do
    if call[1] == 'text' and call[2] == 'Menu' then
      wrist = index
    elseif call[1] == 'line' then
      beams += 1
      firstBeam = if firstBeam == 0 then index else firstBeam
    end
  end
  expect.equal(beams, 2, 'one beam per hand')
  expect.truthy(wrist > 0 and firstBeam > wrist, 'the beams draw after the wrist surfaces')

  -- The right beam presses the panel in front, which focuses it; text, named keys, and chords reach it.
  events.trigger = true
  lovr.update(0.016)
  events.trigger = false
  lovr.update(0.016)
  local before = #events.input
  lovr.textinput('Qq', 0)
  lovr.keypressed('backspace', 0, false)
  expect.truthy(#events.input > before, 'text and named keys reach the focused window')
  events.held.lctrl = true
  before = #events.input
  lovr.textinput('q', 0)
  expect.equal(#events.input, before, 'modified text is handled only by the chord path')
  lovr.keypressed('q', 0, false)
  expect.equal(#events.input, before + 4, 'a chord holds and clears its modifier around one stroke')
  events.held.lctrl = nil
  emit('onError', { message = 'fixture report', traceback = 'fixture trace' })
  lovr.draw(events.pass)

  local startupProcesses = #events.spawned
  testing.host.useConfiguration 'lua/lunette-desktop/tests/support/vr-reload'
  local loaded, failure = require('@lunette').reload()
  expect.truthy(loaded, tostring(failure))
  local initialEnumerations = events.enumerations
  local fixture = vrUi.attach(native)
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  for reload = 1, 10 do
    local controls = assert(_G.vrReloadControls, 'the composition observer is active')
    local currentUi, currentDisplay = controls.ui, controls.display
    fixture:step()
    local retainedPanel = currentUi:panels()[1]
    local retainedDisplay = currentDisplay
    local retainedShow, retainedVisible = currentDisplay.show, currentDisplay.isVisible
    fixture:clickControl(currentUi, 'desktop/menu', 'open')
    fixture:clickControl(currentUi, 'desktop/menu', 'actions', 'right', 'desktop/keyboard/toggle')
    expect.truthy(currentDisplay:isVisible(), 'the menu shows the shared keyboard before reload')
    fixture:clickControl(currentUi, 'desktop/menu', 'actions', 'right', 'desktop/keyboard/toggle')
    expect.falsy(currentDisplay:isVisible(), 'the menu hides the shared keyboard')
    events.logs = {}
    fixture:clickControl(currentUi, 'desktop/menu', 'actions', 'right', 'desktop/reload')
    expect.truthy(retainedPanel.dead, 'reload withdraws the previous UI generation')
    expect.raises(function()
      return retainedDisplay.dead
    end, 'provider activation has ended', 'reload revokes the previous display service')
    expect.falsy(retainedShow(retainedDisplay), 'a cached method cannot reopen a keyboard')
    expect.falsy(retainedVisible(retainedDisplay), 'a cached visibility method is inert')
    expect.equal(#events.logs, 0, 'reload ' .. reload .. ' failed: ' .. tostring(events.logs[1] and events.logs[1][1]))
    expect.equal(events.enumerations, initialEnumerations + reload, 'reload ' .. reload .. ' enumerates once')
    expect.equal(#events.spawned, startupProcesses, 'reload ' .. reload .. ' spawns nothing')
    expect.equal(native.subscriptionCount 'onProcessExited', 0, 'reload ' .. reload .. ' installs no process listener')
    expect.truthy(events.closed == 0 and live(events.windows) == 2, 'reload ' .. reload .. ' closes no window')
    for _, name in ipairs { 'onWindowOpened', 'onMonitorAdded', 'onError' } do
      expect.equal(native.subscriptionCount(name), 1, 'reload ' .. reload .. ' leaves one ' .. name)
    end
    expect.equal(live(events.seats), 2, 'reload ' .. reload .. ' releases the previous seats')
    expect.equal(live(events.claims), 2, 'reload ' .. reload .. ' releases the previous claims')
    lovr.update(0.016)
    expect.equal(lovr.draw(events.pass), false, 'reload ' .. reload .. ' draws')
  end

  expect.equal(lovr.quit(), false, 'quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  native.assertResourcesReleased()
end)

return test
