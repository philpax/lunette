local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local panels = require '@lunette-contracts/panels'
local uiHost = require '@lunette-contracts/ui-host'
local drops = require '@lunette-contracts/drops'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local fixture = require '@testing/ui-host'
local controls = require '../private/controls'
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

test('decoration content equality compares the title and every ordered action field', function()
  local function options(): controls.Options
    return {
      title = 'Title',
      actions = {
        { id = 'restart', label = 'Restart mirror', enabled = true, run = function() end },
        { id = 'select', label = 'Select monitors', enabled = true, run = function() end },
      },
      close = function() end,
    }
  end
  local original = options()
  expect.truthy(controls.sameContent(original, options()), 'fresh callbacks alone do not change rendering')
  expect.truthy(
    controls.sameContent({ title = '', actions = {}, close = function() end }, {
      title = '',
      actions = {},
      close = function() end,
    }),
    'empty action lists are equal'
  )
  local title = options()
  title.title = ''
  expect.falsy(controls.sameContent(original, title), 'the title changes')
  for field, value in { id = 'other', label = 'Retry selection', enabled = false } do
    local changed = options()
    changed.actions[2][field] = value
    expect.falsy(controls.sameContent(original, changed), `the action {field} changes`)
  end
  local reordered = options()
  reordered.actions[1], reordered.actions[2] = reordered.actions[2], reordered.actions[1]
  expect.falsy(controls.sameContent(original, reordered), 'the same actions in another order change rendering')
  local shorter = options()
  table.remove(shorter.actions)
  expect.falsy(controls.sameContent(original, shorter), 'a removed action changes rendering')
  expect.falsy(controls.sameContent(shorter, original), 'an added action changes rendering')
end)

test('unchanged decoration content keeps node props across frames', function()
  local env = boot()
  local kept = {}
  for _, titlebar in { WINDOW, MONITOR } do
    for _, key in { 'close', 'close/face', 'close/face/label' } do
      local handle = node(env, titlebar, key)
      kept[#kept + 1] = { titlebar = titlebar, key = key, handle = handle, props = handle.props }
    end
  end
  for _ = 1, 4 do
    env.running:step()
    for _, entry in kept do
      local current = node(env, entry.titlebar, entry.key)
      expect.equal(current, entry.handle, 'the node is retained')
      expect.equal(current.props, entry.props, 'unchanged decoration content retains node props')
    end
  end
  env.running:close()
end)

test('unchanged decoration content keeps recorded primitives across frames', function()
  local env = boot()
  local records = 0
  local observer = env.running.session:observe(uiHost.capability)
  env.host:registerVisual(
    observer.context,
    'lunette/text',
    function(handle: uiHost.Node, draw: uiHost.Draw, base: (uiHost.Node, uiHost.Draw) -> ())
      records += 1
      base(handle, draw)
    end
  )
  env.running:step()
  env.running:draw()
  expect.truthy(records > 0, 'the production text visual records primitives')
  local before = records
  for _ = 1, 4 do
    env.running:step()
    env.running:draw()
    expect.equal(records, before, 'unchanged decoration content reuses recorded primitives')
  end
  env.running:close()
end)

test('decoration titles and ordered monitor actions follow live content', function()
  local env = boot()
  local function header(titlebar: string): uiHost.Node
    return assert(env.host:find(`{titlebar}:header`))
  end
  local function x(key: string): number
    return (node(env, MONITOR, key):pose():getPosition())
  end
  env.panel.source.title = 'Updated window'
  env.monitor.name = 'Updated monitor'
  env.running:step()
  env.running:step()
  expect.equal(header(WINDOW).props.title, 'Updated window', 'a live window title')
  expect.equal(header(MONITOR).props.title, 'Updated monitor', 'a live monitor name')
  expect.truthy(x 'restart' < x 'select', 'restart precedes select')
  expect.truthy(x 'select' < x 'close', 'select precedes close')
  env.monitor.directCapture = true
  env.running:step()
  env.running:step()
  expect.falsy(env.host:find(`{MONITOR}:header/band/select`), 'direct capture removes portal selection')
  expect.equal(label(env, MONITOR, 'restart'), 'Restart mirror', 'restart remains first')
  env.monitor.directCapture = false
  env.running.native.events.monitorSelection = { state = 'pending' }
  env.running:step()
  env.running:step()
  expect.equal(label(env, MONITOR, 'select'), 'Waiting for permission', 'selection returns with current state')
  expect.truthy(node(env, MONITOR, 'select/face').props.disabledReason, 'pending selection is disabled')
  expect.truthy(x 'restart' < x 'select', 'the order is restored')
  env.running.native.events.monitorSelection = { state = 'idle' }
  env.panel.source.title = ''
  env.running:step()
  env.running:step()
  expect.equal(label(env, MONITOR, 'select'), 'Select monitors', 'an idle selection is enabled again')
  expect.falsy(node(env, MONITOR, 'select/face').props.disabledReason, 'the enabled state changes')
  expect.equal(header(WINDOW).props.title, '', 'an empty live title is published')
  env.running:close()
end)

test('decoration callbacks require an active context while targets remain live', function()
  local env = boot()
  local active = true
  local context = {
    active = function(_self: any): boolean
      return active
    end,
  } :: any
  local closes, dismissals, mirrors = 0, 0, 0
  function env.panel.source.close(self: testing.Window): boolean
    expect.equal(self, env.panel.source, 'close reaches the live window')
    closes += 1
    return true
  end
  function env.monitor.dismiss(self: testing.Monitor)
    expect.equal(self, env.monitor, 'dismiss reaches the live monitor')
    dismissals += 1
  end
  function env.monitor.mirror(self: testing.Monitor): boolean
    expect.equal(self, env.monitor, 'mirror reaches the live monitor')
    mirrors += 1
    return true
  end
  local windowPanel = {
    kind = 'window',
    source = env.panel.source,
    dead = false,
    close = function(): boolean
      return env.panel:close(env.registry.context)
    end,
  } :: any
  local close = controls.options(context, windowPanel, nil, function() end).close
  local restart = controls.options(context, env.mirror, nil, function() end).actions[1].run
  close()
  restart()
  expect.equal(closes, 1, 'an active context can close the live window')
  expect.equal(dismissals, 1, 'an active context can dismiss the live monitor')
  expect.equal(mirrors, 1, 'an active context can restart the live monitor')
  active = false
  close()
  restart()
  expect.equal(closes, 1, 'an inactive context cannot close the live window')
  expect.equal(dismissals, 1, 'an inactive context cannot dismiss the live monitor')
  expect.equal(mirrors, 1, 'an inactive context cannot restart the live monitor')
  expect.falsy(env.panel.dead, 'the window panel remains live')
  expect.falsy(env.panel.source.dead, 'the window source remains live')
  expect.falsy(env.mirror.dead, 'the monitor panel remains live')
  expect.falsy(env.monitor.dead, 'the monitor source remains live')
  env.running:close()
end)

test('retained decoration callbacks use current native methods and live guards', function()
  local env = boot()
  local close = node(env, WINDOW, 'close').props.onActivate
  local restart = node(env, MONITOR, 'restart').props.onActivate
  local select = node(env, MONITOR, 'select').props.onActivate
  for _ = 1, 4 do
    env.running:step()
  end
  expect.equal(node(env, WINDOW, 'close').props.onActivate, close, 'the window callback is retained')
  expect.equal(node(env, MONITOR, 'restart').props.onActivate, restart, 'the restart callback is retained')
  expect.equal(node(env, MONITOR, 'select').props.onActivate, select, 'the selection callback is retained')
  local closes, dismissals, mirrors, selections = 0, 0, 0, 0
  function env.panel.source.close(self: testing.Window): boolean
    expect.equal(self, env.panel.source, 'close reaches the live window')
    closes += 1
    return true
  end
  function env.monitor.dismiss(self: testing.Monitor)
    expect.equal(self, env.monitor, 'dismiss reaches the live monitor')
    dismissals += 1
  end
  function env.monitor.mirror(self: testing.Monitor): boolean
    expect.equal(self, env.monitor, 'mirror reaches the live monitor')
    mirrors += 1
    return false
  end
  close()
  local restarted, failure = pcall(restart)
  expect.falsy(restarted, 'the current mirror refusal is reported')
  expect.truthy(tostring(failure):find('monitor capture: restart was refused for screen-a', 1, true), tostring(failure))
  local selectMonitors = lunette.selectMonitors
  lunette.selectMonitors = function(): (boolean, string)
    selections += 1
    return false, `refusal {selections}`
  end
  local ok, message = pcall(function()
    select()
    env.running:step()
    expect.equal(label(env, MONITOR, 'select'), 'Select monitors: refusal 1', 'the retained callback publishes refusal')
    select()
    env.running:step()
    expect.equal(
      label(env, MONITOR, 'select'),
      'Select monitors: refusal 2',
      'the same callback updates shared refusal'
    )
    env.panel.source.dead = true
    env.monitor.dead = true
    close()
    restart()
    select()
    expect.equal(closes, 1, 'a dead window receives no close')
    expect.equal(dismissals, 1, 'a dead monitor receives no dismiss')
    expect.equal(mirrors, 1, 'a dead monitor receives no mirror')
    expect.equal(selections, 2, 'a dead monitor receives no selection')
    env.panel.source.dead = false
    env.monitor.dead = false
    env.panel:destroy(env.registry.context)
    env.mirror:close(env.registry.context)
    local removedDismissals = dismissals
    close()
    restart()
    select()
    expect.equal(closes, 1, 'a removed window receives no close')
    expect.equal(dismissals, removedDismissals, 'a removed monitor receives no dismiss from retained callbacks')
    expect.equal(mirrors, 1, 'a removed monitor receives no restart')
    expect.equal(selections, 2, 'a removed monitor receives no selection')
    env.running:close()
    local stoppedDismissals = dismissals
    close()
    restart()
    select()
    expect.equal(closes, 1, 'an inactive owner receives no close')
    expect.equal(dismissals, stoppedDismissals, 'an inactive owner receives no dismiss')
    expect.equal(mirrors, 1, 'an inactive owner receives no mirror')
    expect.equal(selections, 2, 'an inactive owner receives no selection')
  end)
  lunette.selectMonitors = selectMonitors
  assert(ok, message)
end)

test('unchanged decoration content still follows theme, visibility, death, and removal', function()
  local env = boot()
  local face = node(env, WINDOW, 'close/face')
  local tokens = face.theme
  local theme = env.running.session:observe(require('@lunette-contracts/theme').capability)
  theme.service:setMode(if tokens.mode == 'dark' then 'light' else 'dark')
  env.running:step()
  env.running:step()
  expect.equal(node(env, WINDOW, 'close/face'), face, 'theme changes retain the node')
  expect.truthy(face.theme ~= tokens, 'theme invalidation reaches an unchanged titlebar')
  expect.equal(face.theme.mode, env.host:theme().mode, 'the titlebar uses the current theme')
  local hiding = env.panel:setHidden(env.registry.context, true)
  env.running:step()
  env.running:step()
  local function visible(name: string): boolean
    for _, registration in env.host:inspect().registrations do
      if registration.kind == 'panel' and registration.name == name then
        return registration.details.visible
      end
    end
    return false
  end
  expect.falsy(visible(WINDOW), 'the titlebar follows a hidden target')
  hiding:dispose()
  env.running:step()
  env.running:step()
  expect.truthy(visible(WINDOW), 'the titlebar follows a shown target')
  env.panel.source.dead = true
  env.running:step()
  expect.falsy(env.host:find(`{WINDOW}:header`), 'a dead source loses its titlebar')
  local monitorClose = node(env, MONITOR, 'close').props.onActivate
  monitorClose()
  expect.falsy(env.host:find(`{MONITOR}:header`), 'a removed target loses its titlebar immediately')
  env.running:close()
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
