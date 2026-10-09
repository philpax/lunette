local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local drops = require '@lunette-contracts/drops'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local test = testing.suite()

local HEADER_STYLE = {
  barHeight = 0.05,
  cornerRadius = 0.012,
  margin = 0.03,
  borderThickness = 0.014,
  borderDepth = 0.003,
  borderColor = { 0.71, 0.19, 0.37, 1 },
  borderHighlightColor = { 0.13, 0.79, 0.41, 1 },
}
local BODY_STYLE = {
  windowRadius = 0.035,
  monitorRadius = 0,
  borderThickness = 0.004,
  borderColor = { 0.21, 0.31, 0.61, 1 },
  borderHighlightColor = { 0.81, 0.41, 0.11, 1 },
}

local function withTitlebar(provider, run)
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
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = { style = BODY_STYLE } },
    provider,
    'desktop/render',
    {
      id = 'desktop/decorations',
      definition = require '@lunette-plugins/desktop/decorations',
      config = { style = HEADER_STYLE },
    },
    'desktop/monitors',
  }, { native = native })
  local registry = running.session:observe(panels.capability)
  local window = native.newWindow(7)
  local closeRequests = 0
  function window:close()
    closeRequests += 1
    return true
  end
  local panel = registry.service:fromWindow(registry.context, window, {
    pose = lovr.math.newMat4():translate(-2, 1, -2),
    width = 1,
  })
  running:step()
  local mirror = assert(registry.service:forSource(monitor))
  mirror:setPose(lovr.math.newMat4():translate(3, 1, -2))
  running:step()
  run(running, registry, panel, monitor, function()
    return closeRequests
  end)
  running:close()
end

local function sameColor(actual, wanted)
  return actual
    and actual[1] == wanted[1]
    and actual[2] == wanted[2]
    and actual[3] == wanted[3]
    and actual[4] == wanted[4]
end

local function offeredBars(running, panel)
  local bars = {}
  for _, surface in running.session:observe(surfaces.capability).service:all() do
    if surface ~= panel and surface.kind == panel.kind and surface.source == panel.source then
      bars[#bars + 1] = surface
    end
  end
  return bars
end

local function selection(widgets)
  for _, panel in widgets:panels() do
    local description = panel:describe()
    if description.name == 'desktop/decorations/monitor/screen-a' then
      for _, control in description.controls do
        if control.id == 'select/monitor/screen-a' then
          return control
        end
      end
    end
  end
  error('the monitor has no selection control', 0)
end

local function combinedOutline(running, target, color)
  running.native.events.draw = {}
  running:draw()
  local px, py = target.pose:getPosition()
  local found
  local count = 0
  for _, call in running.native.events.draw do
    if call.draw then
      expect.falsy(sameColor(call.state.setColor, BODY_STYLE.borderColor), 'the body border is delegated to the header')
      expect.falsy(
        sameColor(call.state.setColor, BODY_STYLE.borderHighlightColor),
        'the body highlight border is delegated'
      )
    end
    if call[1] == 'draw' and sameColor(call.state.setColor, color) then
      local x, y = call[3]:getPosition()
      if math.abs(x - px) < 1e-5 and math.abs(y - py) < 1e-5 then
        found = call[2]
        count += 1
      end
    end
  end
  expect.equal(count, 1, 'the target draws one combined outline, not a second titlebar border')
  return assert(found)
end

test('titlebar closes windows by request, refuses are reported, and dismisses monitor panels', function()
  withTitlebar('ui', function(running, registry, panel, monitor, requests)
    local widgets = running.session:observe(ui.capability).service
    local windowName = 'desktop/decorations/window/7'
    local monitorName = 'desktop/decorations/monitor/screen-a'
    local description = running:discover(widgets, windowName, 'close/window/7')
    local pose = lovr.math.newMat4(table.unpack(description.pose))
    local _, y = pose:getPosition()
    expect.near(y, 1 + panel.height / 2 + 0.025, 1e-5, 'controls occupy the joined titlebar')
    local windowOutline = combinedOutline(running, panel, HEADER_STYLE.borderColor)
    local bar = offeredBars(running, panel)[1]
    expect.truthy(bar, 'the action controls share the offered header')
    local px, py, pz = panel.pose:getPosition()
    local _, by = bar.pose:getPosition()
    local _, headerBottom = lovr.math.newMat4(bar.pose):translate(0, -bar.height / 2, 0):getPosition()
    local _, bodyTop = lovr.math.newMat4(panel.pose):translate(0, panel.height / 2, 0):getPosition()
    expect.equal(headerBottom, bodyTop, 'the controls header meets its body with zero seam')
    running:pose('right', lovr.math.newMat4():translate(px - 0.2, by, pz + 0.5))
    running:tracked('right', true)
    running:step()
    expect.equal(
      combinedOutline(running, panel, HEADER_STYLE.borderHighlightColor),
      windowOutline,
      'header hover changes the whole outline color without duplicating its contour'
    )
    running:tracked('right', false)
    running:step()
    running:clickControl(widgets, windowName, 'close/window/7')
    expect.equal(requests(), 1, 'the close button sends one application close request')
    expect.falsy(panel.dead, 'a close request waits for the client to unmap')
    function panel.source:close()
      return false
    end
    running:clickControl(widgets, windowName, 'close/window/7')
    expect.equal(#running.native.events.reported, 1)
    expect.truthy(running.native.events.reported[1].message:find('panel close: request was refused', 1, true))
    expect.falsy(panel.dead, 'a refused close leaves the panel alive')
    local mirror = assert(registry.service:forSource(monitor))
    combinedOutline(running, mirror, HEADER_STYLE.borderColor)
    local monitorDescription = running:discover(widgets, monitorName, 'close/monitor/screen-a')
    local _, monitorY = lovr.math.newMat4(table.unpack(monitorDescription.pose)):getPosition()
    local _, mirrorY = mirror.pose:getPosition()
    expect.near(
      monitorY,
      mirrorY + mirror.height / 2 + HEADER_STYLE.barHeight / 2,
      1e-5,
      'mirror actions use the joined header'
    )
    running:clickControl(widgets, monitorName, 'restart/monitor/screen-a')
    expect.equal(running.native.events.mirrored, 2)
    running:clickControl(widgets, monitorName, 'select/monitor/screen-a')
    expect.equal(running.native.events.monitorSelections, 1)
    running:clickControl(widgets, monitorName, 'close/monitor/screen-a')
    expect.truthy(mirror.dead, 'closing removes the mirror panel')
    expect.equal(running.native.events.unmirrored, 2, 'closing dismisses capture once')
    expect.falsy(monitor.dead, 'closing does not unplug the host monitor')
    running:step()
    for _, widget in widgets:panels() do
      expect.falsy(widget:describe().name == monitorName, 'closed titlebar controls are removed')
    end
    local hiding = panel:setHidden(registry.context, { hidden = true })
    running:step()
    expect.equal(#offeredBars(running, panel), 0, 'the bar of a hidden panel')
    for _, surface in running.session:observe(surfaces.capability).service:all() do
      expect.truthy(surface ~= panel, 'a hidden panel')
    end
    hiding:dispose()
  end)
end)

test('titlebar and content grabs move the owning panel and emit one drop', function()
  withTitlebar('ui', function(running, registry, panel, _monitor, requests)
    local released = {}
    local observer = running.session:observe(drops.capability)
    observer.service:onDropped(observer.context, {
      run = function(drop)
        released[#released + 1] = drop
      end,
    })
    local function drag(button, title, rightEdge)
      local px, py, pz = panel.pose:getPosition()
      local y = if title then py + panel.height / 2 + 0.025 else py
      local x = if rightEdge then px + panel.width / 2 - 0.025 else px - 0.2
      local origin = lovr.math.newMat4():translate(x, y, pz + 0.5)
      running:pose('right', origin)
      running:tracked('right', true)
      running:button('right', button, false)
      running:step()
      running:button('right', button, true)
      running:step()
      running:pose('right', lovr.math.newMat4(origin):translate(0.3, 0.1, -0.1))
      running:step()
      local x, movedY, movedZ = panel.pose:getPosition()
      expect.near(x, px + 0.3, 1e-5, button .. ' moves the owning panel')
      expect.near(movedY, py + 0.1, 1e-5)
      expect.near(movedZ, pz - 0.1, 1e-5)
      running:button('right', button, false)
      running:step()
      expect.equal(registry.service:forSource(released[#released].surface.source), panel)
    end
    drag('trigger', true)
    drag('grip', false)
    drag('grip', true, true)
    expect.equal(#released, 3, 'each gesture emits one panel drop')
    expect.equal(requests(), 0, 'grip over X never closes the application')
    local clicks = 0
    for _, event in running.native.events.input do
      if event.kind == 'button' then
        clicks += 1
      end
    end
    expect.equal(clicks, 0, 'title dragging does not send application clicks')
  end)
end)

test('monitor selection shows a refused request, then a pending, failed, or retried selection', function()
  withTitlebar('ui', function(running)
    local widgets = running.session:observe(ui.capability).service
    local native = running.native
    local selectMonitors = lunette.selectMonitors
    lunette.selectMonitors = function()
      return false, 'portal unavailable'
    end
    local ok, message = pcall(function()
      running:clickControl(widgets, 'desktop/decorations/monitor/screen-a', 'select/monitor/screen-a')
      expect.truthy(selection(widgets).label:find('portal unavailable', 1, true))
      running:step()
      expect.truthy(selection(widgets).label:find('portal unavailable', 1, true))
      expect.equal(native.events.monitorSelections, nil, 'a refused request does not prompt again')
    end)
    lunette.selectMonitors = selectMonitors
    if not ok then
      error(message, 0)
    end
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
  end)
end)

return test
