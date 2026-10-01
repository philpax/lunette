-- Panel rendering and monitor mirrors.
--
-- Pointing is a separate consumer, so a laser or interaction outage leaves
-- panels updating and drawing.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local callbacks = require '../desktop/callbacks'
local panels = require '@lunette-contracts/panels'
local surface = require '@lunette-contracts/surface'

local required: plugin.Declaration = { panels = panels.capability }
export type Config = { read callbacks: typeof(callbacks) }

return plugin.define {
  name = 'desktop/base',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local callbacks = config.callbacks
    local panelService: panels.Service = context:require(panels.capability)
    local mirrors: { [string]: panels.MonitorPanel } = {}
    -- A mirror lasts as long as its panel. The capture and the removal
    -- listener are released when the panel is removed, whether the monitor
    -- went away or the panel was destroyed, so hotplug does not accumulate
    -- effects on this activation.
    local function mirror(monitor: lunette.Monitor): ()
      if monitor.dead then
        return
      end
      local existing = mirrors[monitor.id]
      if existing and not existing.dead then
        if not existing.source.dead then
          return
        end
        -- The monitor was replugged before an update retired the panel over
        -- its previous handle.
        existing:destroy(context)
      end
      if panelService:forSource(monitor) then
        return
      end
      local mirrored = context:effect(function(): () -> ()
        monitor:mirror()
        return function(): ()
          if not monitor.dead then
            monitor:dismiss()
          end
        end
      end)
      local created = panelService:fromMonitor(context, monitor, {
        pose = lovr.math.newMat4():translate(0, 1.5, -2),
        width = 2,
      })
      if created.dead then
        mirrored:dispose()
        return
      end
      mirrors[monitor.id] = created
      local removal: plugin.Effect
      removal = panelService:onRemoved(context, created, function(): ()
        if mirrors[monitor.id] == created then
          mirrors[monitor.id] = nil
        end
        removal:dispose()
        mirrored:dispose()
      end)
    end
    context:on(lunette.onMonitorAdded, function(event: lunette.MonitorAddedEvent)
      if event.monitor then
        mirror(event.monitor)
      end
    end)
    for _, monitor in pairs(lunette.monitors()) do
      mirror(monitor)
    end
    callbacks.onSurfaces(context, function(): { surface.Surface }
      local result: { surface.Surface } = {}
      local function add(value: surface.Surface): ()
        result[#result + 1] = value
      end
      for _, item in ipairs(panelService:all()) do
        if not item.dead then
          add(item)
        end
      end
      return result
    end)
    callbacks.onUpdate(context, function(_dt: number)
      panelService:update()
    end, 100)
    callbacks.onDraw(context, function(pass: Pass)
      panelService:draw(pass)
      if #panelService:all() == 0 then
        pass:text(
          'lunette: no windows yet',
          lovr.math.mat4():translate(0, 1.5, -1.5):scale(0.08),
          0,
          'center',
          'middle'
        )
      end
    end, 100)
  end,
}
