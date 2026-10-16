local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local panels = require '@lunette-contracts/panels'
local uiHost = require '@lunette-contracts/ui-host'
local drops = require '@lunette-contracts/drops'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local fixture = require '@testing/ui-host'
local config = require '../config'
local test = testing.suite()

type WindowPanel = {
  read source: testing.Window,
  read pose: Mat4,
  read height: number,
  read dead: boolean,
  read setPose: (WindowPanel, Mat4) -> (),
  read setHidden: (WindowPanel, testing.Owner, boolean) -> testing.Effect,
}
type Environment = {
  running: vrUi.Fixture,
  registry: testing.Observed<panels.Service>,
  monitor: testing.Monitor,
  host: uiHost.Service,
  closeRequests: number,
  panel: WindowPanel,
  mirror: panels.Panel,
}

local WINDOW = 'desktop/decorations/window/7'
local MONITOR = 'desktop/decorations/monitor/screen-a'

local function boot(): Environment
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
    'ui-host',
    'ui-standard',
    'desktop/render',
    'desktop/decorations',
    'desktop/monitors',
  }, { native = native })
  local registry = running.session:observe(panels.capability)
  local env: Environment = {
    running = running,
    registry = registry,
    monitor = monitor,
    host = assert(running.session:observe(uiHost.capability).service),
    closeRequests = 0,
  } :: any
  local window = native.newWindow(7)
  function window.close(self: testing.Window): boolean
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
  running:step()
  return env
end

-- A titlebar node by its key under the header band, such as 'close'.
local function node(env: Environment, titlebar: string, key: string): uiHost.Node
  return assert(env.host:find(`{titlebar}:header/band/{key}`), `no titlebar node {key} on {titlebar}`)
end

local function click(env: Environment, titlebar: string, key: string)
  env.running:click(fixture.nodeGeometry(node(env, titlebar, `{key}/face`)), 0.5, 0.5)
end

local function label(env: Environment, titlebar: string, key: string): string
  return node(env, titlebar, `{key}/face/label`).props.text
end

test('decorations take their appearance from the theme, with an optional height', function()
  expect.equal(config.schema.parse({}).height, nil, 'the theme sets the height by default')
  expect.equal(config.schema.parse({ height = 0.05 }).height, 0.05)
end)

test('a window titlebar requests close, reports a refusal, and is withdrawn while the window is hidden', function()
  local env = boot()
  click(env, WINDOW, 'close')
  expect.equal(env.closeRequests, 1, 'the close button sends one close request')
  expect.falsy(env.panel.dead, 'the panel waits for the client to unmap')
  function env.panel.source.close(self: testing.Window): boolean
    return false
  end
  click(env, WINDOW, 'close')
  local reports = env.running.native.events.reported
  expect.equal(#reports, 1, 'a refused close is reported')
  expect.truthy(reports[1].message:find('panel close: request was refused', 1, true), reports[1].message)
  table.clear(reports)
  local before = #env.running.session:observe(surfaces.capability).service:all()
  local hiding = env.panel:setHidden(env.registry.context, true)
  env.running:step()
  env.running:step()
  local after = #env.running.session:observe(surfaces.capability).service:all()
  expect.truthy(after <= before - 2, 'a hidden window offers neither itself nor its titlebar')
  hiding:dispose()
end)

test('dragging a window titlebar moves the window and drops it once', function()
  local env = boot()
  local released: { drops.Drop } = {}
  local observer = env.running.session:observe(drops.capability)
  observer.service:onDropped(observer.context, {
    run = function(drop: drops.Drop)
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
  click(env, MONITOR, 'restart')
  expect.equal(env.running.native.events.mirrored, 2, 'restart mirrors again')
  click(env, MONITOR, 'select')
  expect.equal(env.running.native.events.monitorSelections, 1, 'select requests a monitor selection')
  click(env, MONITOR, 'close')
  expect.truthy(env.mirror.dead, 'closing removes the mirror panel')
  expect.falsy(env.monitor.dead, 'closing does not unplug the host monitor')
end)

test('monitor selection shows a refused, pending, and failed request, and retries only when asked', function()
  local env = boot()
  local native = env.running.native
  local selectMonitors = lunette.selectMonitors
  lunette.selectMonitors = function(): (boolean, string)
    return false, 'portal unavailable'
  end
  local ok, message = pcall(click, env, MONITOR, 'select')
  lunette.selectMonitors = selectMonitors
  assert(ok, message)
  env.running:step()
  expect.equal(label(env, MONITOR, 'select'), 'Select monitors: portal unavailable', 'a refused request')
  click(env, MONITOR, 'select')
  expect.equal(native.events.monitorSelections, 1, 'one request')
  env.running:step()
  expect.equal(label(env, MONITOR, 'select'), 'Waiting for permission', 'a pending request')
  expect.truthy(node(env, MONITOR, 'select/face').props.disabledReason, 'a pending request cannot be repeated')
  native.events.monitorSelection = { state = 'failed', message = 'selection cancelled' }
  env.running:step()
  env.running:step()
  expect.equal(label(env, MONITOR, 'select'), 'Retry selection: selection cancelled', 'a failed request')
  expect.equal(native.events.monitorSelections, 1, 'a failure does not retry by itself')
  click(env, MONITOR, 'select')
  expect.equal(native.events.monitorSelections, 2, 'a retry starts a fresh request')
end)

return test
