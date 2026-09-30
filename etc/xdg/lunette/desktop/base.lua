-- Panel rendering, monitor mirrors, and two-hand pointing.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local callbacks = require '../desktop/callbacks'
local panels = require '@lunette-contracts/panels'
local laser = require '@lunette-contracts/laser'
local surface = require '@lunette-contracts/surface'

local required: plugin.Declaration = { panels = panels.capability, laser = laser.capability }
export type Config = { read callbacks: typeof(callbacks) }

return plugin.define(
  function(config: Config): Config
    return config
  end,
  required,
  {},
  function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local callbacks = config.callbacks
    local panelService: panels.Service = context:require(panels.capability)
    local laserService: laser.Service = context:require(laser.capability)
    local mirrors: { [string]: panels.MonitorPanel } = {}
    local function mirror(monitor: lunette.Monitor): ()
      local existing = mirrors[monitor.id]
      if monitor.dead or (existing and not existing.dead) or panelService:forSource(monitor) then
        return
      end
      context:effect(function(): () -> ()
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
      mirrors[monitor.id] = created
    end
    context:effect(function(): () -> ()
      local cancel = lunette.onMonitorAdded(function(event: lunette.MonitorAddedEvent)
        if context:active() and event.monitor then
          mirror(event.monitor)
        end
      end)
      for _, monitor in pairs(lunette.monitors()) do
        mirror(monitor)
      end
      return cancel
    end)
    laserService:attach(context)
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
      laserService:update(callbacks.surfaces())
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
    callbacks.onDraw(context, function(pass: Pass)
      laserService:draw(pass)
    end, 300)
  end
)
