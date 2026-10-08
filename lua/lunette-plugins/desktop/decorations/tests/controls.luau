local testing = require '@testing'
local expect = testing.expect
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local drops = require '@lunette-contracts/drops'
local vrUi = require '@testing/vr-ui'
local test = testing.suite()

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
    'laser',
    'keyboard',
    'desktop/pointing',
    'panels',
    provider,
    'desktop/render',
    'desktop/decorations',
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
  local ok, message = pcall(run, running, registry, panel, monitor, function()
    return closeRequests
  end)
  running:close()
  if not ok then
    error(message, 0)
  end
end

for _, provider in
  {
    { name = 'real', entry = 'ui' },
    { name = 'substitute', entry = { id = 'ui', definition = require('@testing/ui-substitute').definition } },
  }
do
  test(provider.name .. ' titlebar closes windows by request and dismisses monitor panels', function()
    withTitlebar(provider.entry, function(running, registry, panel, monitor, requests)
      local widgets = running.session:observe(ui.capability).service
      local windowName = 'desktop/decorations/window/7'
      local monitorName = 'desktop/decorations/monitor/screen-a'
      local description = running:discover(widgets, windowName, 'close/window/7')
      local pose = lovr.math.newMat4(table.unpack(description.pose))
      local _, y = pose:getPosition()
      expect.near(y, 1 + panel.height / 2 + 0.035, 1e-5, 'controls occupy the titlebar')
      running:clickControl(widgets, windowName, 'close/window/7')
      expect.equal(requests(), 1, 'the close button sends one application close request')
      expect.falsy(panel.dead, 'a close request waits for the client to unmap')
      local mirror = assert(registry.service:forSource(monitor))
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
    end)
  end)

  test(provider.name .. ' titlebar and content grabs move the owning panel and emit one drop', function()
    withTitlebar(provider.entry, function(running, registry, panel, _monitor, requests)
      local released = {}
      local observer = running.session:observe(drops.capability)
      observer.service:onDropped(observer.context, {
        run = function(drop)
          released[#released + 1] = drop
        end,
      })
      local function drag(button, title, rightEdge)
        local px, py, pz = panel.pose:getPosition()
        local y = if title then py + panel.height / 2 + 0.035 else py
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

  test(provider.name .. ' titlebar hide cancels a held close gesture', function()
    withTitlebar(provider.entry, function(running, registry, panel, _monitor, requests)
      local widgets = running.session:observe(ui.capability).service
      local description, control = running:discover(widgets, 'desktop/decorations/window/7', 'close/window/7')
      running:aim(description, control.bounds.x + control.bounds.width / 2, control.bounds.height / 2)
      running:step()
      running:button('right', 'trigger', true)
      running:step()
      local hidden = panel:setHidden(registry.context, { hidden = true })
      running:step()
      hidden:dispose()
      running:step()
      running:button('right', 'trigger', false)
      running:step()
      expect.equal(requests(), 0, 'hiding does not convert cancellation to activation')
      running:clickControl(widgets, 'desktop/decorations/window/7', 'close/window/7')
      expect.equal(requests(), 1, 'a fresh gesture still works after showing the panel')
    end)
  end)
end

test('a refused titlebar close reports the request and leaves the application panel alive', function()
  withTitlebar('ui', function(running, _registry, panel)
    function panel.source:close()
      return false
    end
    local widgets = running.session:observe(ui.capability).service
    running:clickControl(widgets, 'desktop/decorations/window/7', 'close/window/7')
    expect.equal(#running.native.events.reported, 1)
    expect.truthy(running.native.events.reported[1].message:find('panel close: request was refused', 1, true))
    expect.falsy(panel.dead)
  end)
end)

return test
