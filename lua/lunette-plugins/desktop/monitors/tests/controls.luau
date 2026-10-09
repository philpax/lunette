local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local vrUi = require '@testing/vr-ui'
local test = testing.suite()

local function boot(provider)
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
    provider,
    'menu',
    'desktop/actions',
    'desktop/decorations',
    'desktop/monitors',
  }, { native = native })
  running:step()
  return running, monitor, running.session:observe(ui.capability).service, running.session:observe(panels.capability)
end

local function withBoot(provider, run)
  local running, monitor, widgets, registry = boot(provider)
  run(running, monitor, widgets, registry)
  running:close()
end

local function toolbar(widgets)
  for _, panel in widgets:panels() do
    if panel:describe().name == 'desktop/decorations/monitor/screen-a' then
      return panel
    end
  end
  error('the monitor has no titlebar controls', 0)
end

local function position(panel)
  return lovr.math.newMat4(table.unpack(panel:describe().pose)):getPosition()
end

local function selection(widgets)
  for _, control in toolbar(widgets):describe().controls do
    if control.id == 'select/monitor/screen-a' then
      return control
    end
  end
  error('the monitor has no selection control', 0)
end

test('UI keeps capture recovery in automatically mirrored monitor titlebars', function()
  withBoot('ui', function(running, monitor, widgets, registry)
    local native = running.native
    expect.equal(native.events.mirrored, 1, 'capture starts without a menu action')
    expect.equal(native.events.monitorSelections, nil, 'controls do not prompt automatically')
    local mirror = assert(registry.service:forSource(monitor))
    local controls = toolbar(widgets)
    local x, y, z = position(controls)
    expect.near(x, mirror.width / 2 - controls:describe().width / 2, 1e-5)
    expect.near(y, select(2, mirror.pose:getPosition()) + mirror.height / 2 + 0.025, 1e-5)
    expect.near(z, select(3, mirror.pose:getPosition()) + 0.001, 1e-5)
    running:clickControl(widgets, 'desktop/decorations/monitor/screen-a', 'restart/monitor/screen-a')
    expect.equal(native.events.unmirrored, 1, 'only the selected monitor is dismissed')
    expect.equal(native.events.mirrored, 2, 'the selected monitor restarts')
    running:clickControl(widgets, 'desktop/decorations/monitor/screen-a', 'select/monitor/screen-a')
    expect.equal(native.events.monitorSelections, 1)
    expect.equal(selection(widgets).enabled, false)
    expect.equal(selection(widgets).label, 'Waiting for permission')
    for _ = 1, 4 do
      running:step()
    end
    expect.equal(native.events.monitorSelections, 1, 'pending selection does not prompt again')
    native.events.monitorSelection = { state = 'failed', message = 'selection cancelled' }
    running:step()
    expect.equal(selection(widgets).enabled, true)
    expect.truthy(selection(widgets).label:find('selection cancelled', 1, true))
    expect.equal(native.events.monitorSelections, 1, 'cancellation does not retry')
    running:clickControl(widgets, 'desktop/decorations/monitor/screen-a', 'select/monitor/screen-a')
    expect.equal(native.events.monitorSelections, 2, 'an explicit retry starts a fresh request')
    local hidden = mirror:setHidden(registry.context, { hidden = true })
    running:step()
    expect.equal(controls:describe().visible, false)
    hidden:dispose()
    mirror:setPose(lovr.math.newMat4():translate(1, 2, -3):rotate(0.4, 0, 1, 0))
    running:step()
    local expected = lovr.math
      .newMat4(mirror.pose)
      :translate(mirror.width / 2 - controls:describe().width / 2, mirror.height / 2 + 0.025, 0.001)
    local expectedX, expectedY, expectedZ = expected:getPosition()
    x, y, z = position(controls)
    expect.near(x, expectedX, 1e-5)
    expect.near(y, expectedY, 1e-5)
    expect.near(z, expectedZ, 1e-5)
    running.session.instances.ui:disable()
    expect.truthy(controls.dead, 'a UI outage disposes the toolbar')
    expect.falsy(mirror.dead, 'a UI outage leaves capture active')
    running.session.instances.ui:enable()
    running:step()
    widgets = running.session:observe(ui.capability).service
    expect.falsy(toolbar(widgets).dead, 'UI recovery recreates the toolbar')
    monitor.dead = true
    registry.service:update()
    running:step()
    expect.equal(#widgets:panels(), 0, 'monitor removal disposes its toolbar')
  end)
end)

test('panel selection displays a refused request without a prompt loop', function()
  withBoot('ui', function(running, _monitor, widgets)
    local selectMonitors = lunette.selectMonitors
    lunette.selectMonitors = function()
      return false, 'portal unavailable'
    end
    local ok, message = pcall(function()
      running:clickControl(widgets, 'desktop/decorations/monitor/screen-a', 'select/monitor/screen-a')
      expect.truthy(selection(widgets).label:find('portal unavailable', 1, true))
      running:step()
      expect.truthy(selection(widgets).label:find('portal unavailable', 1, true))
      expect.equal(running.native.events.monitorSelections, nil)
    end)
    lunette.selectMonitors = selectMonitors
    if not ok then
      error(message, 0)
    end
  end)
end)

return test
