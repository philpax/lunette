local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local drops = require '@lunette-contracts/drops'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local test = testing.suite()

local WINDOW = 'desktop/decorations/window/7'
local MONITOR = 'desktop/decorations/monitor/screen-a'

local function boot()
  local native = testing.native()
  local monitor = native.newMonitor 'screen-a'
  native.events.monitors = { monitor }
  local running = vrUi.boot({
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'theme',
    'laser',
    'keyboard',
    'desktop/pointing',
    'panels',
    'ui',
    'desktop/render',
    'desktop/decorations',
    'desktop/monitors',
  }, { native = native })
  local registry = running.session:observe(panels.capability)
  local env = {
    running = running,
    registry = registry,
    monitor = monitor,
    widgets = running.session:observe(ui.capability).service,
    closeRequests = 0,
  }
  local window = native.newWindow(7)
  function window:close()
    env.closeRequests += 1
    return true
  end
  env.panel = registry.service:fromWindow(registry.context, window, {
    pose = lovr.math.newMat4():translate(-2, 1, -2),
    width = 1,
  })
  running:step()
  env.mirror = assert(registry.service:forSource(monitor))
  env.mirror:setPose(lovr.math.newMat4():translate(3, 1, -2))
  running:step()
  return env
end

local function click(env, name, id)
  env.running:clickControl(env.widgets, name, id)
end

-- Reads the control directly, since discovery finds only enabled controls and a pending selection is disabled.
local function selection(env)
  for _, panel in env.widgets:panels() do
    for _, control in panel:describe().controls do
      if control.id == 'select/monitor/screen-a' then
        return control
      end
    end
  end
  error('the monitor has no selection control', 0)
end

test('a window titlebar requests close, reports a refusal, and is withdrawn while the window is hidden', function()
  local env = boot()
  click(env, WINDOW, 'close/window/7')
  expect.equal(env.closeRequests, 1, 'the close button sends one close request')
  expect.falsy(env.panel.dead, 'the panel waits for the client to unmap')
  function env.panel.source:close()
    return false
  end
  click(env, WINDOW, 'close/window/7')
  local reports = env.running.native.events.reported
  expect.equal(#reports, 1, 'a refused close is reported')
  expect.truthy(reports[1].message:find('panel close: request was refused', 1, true), reports[1].message)
  table.clear(reports)
  local hiding = env.panel:setHidden(env.registry.context, { hidden = true })
  env.running:step()
  for _, surface in env.running.session:observe(surfaces.capability).service:all() do
    expect.truthy(surface.source ~= env.panel.source, 'a hidden window offers no titlebar')
  end
  hiding:dispose()
end)

test('dragging a window titlebar moves the window and drops it once', function()
  local env = boot()
  local released = {}
  local observer = env.running.session:observe(drops.capability)
  observer.service:onDropped(observer.context, {
    run = function(drop)
      released[#released + 1] = drop
    end,
  })
  local px, py, pz = env.panel.pose:getPosition()
  local origin = lovr.math.newMat4():translate(px - 0.2, py + env.panel.height / 2 + 0.025, pz + 0.5)
  env.running:pose('right', origin)
  env.running:tracked('right', true)
  env.running:step()
  env.running:button('right', 'trigger', true)
  env.running:step()
  env.running:pose('right', lovr.math.newMat4(origin):translate(0.3, 0.1, -0.1))
  env.running:step()
  env.running:button('right', 'trigger', false)
  env.running:step()
  local x, y, z = env.panel.pose:getPosition()
  expect.near(x, px + 0.3, 1e-5, 'the window moves in x')
  expect.near(y, py + 0.1, 1e-5, 'the window moves in y')
  expect.near(z, pz - 0.1, 1e-5, 'the window moves in z')
  expect.equal(#released, 1, 'one drop')
  expect.equal(env.registry.service:forSource(released[1].surface.source), env.panel, 'the drop names the window')
  expect.equal(env.closeRequests, 0, 'dragging never closes the window')
end)

test('a monitor titlebar restarts the mirror, selects monitors, and closes the mirror only', function()
  local env = boot()
  click(env, MONITOR, 'restart/monitor/screen-a')
  expect.equal(env.running.native.events.mirrored, 2, 'restart mirrors again')
  click(env, MONITOR, 'select/monitor/screen-a')
  expect.equal(env.running.native.events.monitorSelections, 1, 'select requests a monitor selection')
  click(env, MONITOR, 'close/monitor/screen-a')
  expect.truthy(env.mirror.dead, 'closing removes the mirror panel')
  expect.falsy(env.monitor.dead, 'closing does not unplug the host monitor')
end)

test('monitor selection shows a refused, pending, and failed request, and retries only when asked', function()
  local env = boot()
  local native = env.running.native
  local selectMonitors = lunette.selectMonitors
  lunette.selectMonitors = function()
    return false, 'portal unavailable'
  end
  local ok, message = pcall(click, env, MONITOR, 'select/monitor/screen-a')
  lunette.selectMonitors = selectMonitors
  assert(ok, message)
  expect.equal(selection(env).label, 'Select monitors: portal unavailable', 'a refused request')
  click(env, MONITOR, 'select/monitor/screen-a')
  expect.equal(native.events.monitorSelections, 1, 'one request')
  local pending = selection(env)
  expect.equal(pending.label, 'Waiting for permission', 'a pending request')
  expect.equal(pending.enabled, false, 'a pending request cannot be repeated')
  native.events.monitorSelection = { state = 'failed', message = 'selection cancelled' }
  env.running:step()
  expect.equal(selection(env).label, 'Retry selection: selection cancelled', 'a failed request')
  expect.equal(native.events.monitorSelections, 1, 'a failure does not retry by itself')
  click(env, MONITOR, 'select/monitor/screen-a')
  expect.equal(native.events.monitorSelections, 2, 'a retry starts a fresh request')
end)

return test
