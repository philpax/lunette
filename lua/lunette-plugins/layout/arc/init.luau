-- Registers a layout that arranges panels on an arc. Apply options merge over the registered tuning.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'
local geometry = require '@lunette-plugins/layout/arc/geometry'
local config = require '@lunette-plugins/layout/arc/config'
local configured = require '@lunette-plugin/configured'

local arc = {}

export type Tuning = geometry.Tuning

export type Options = config.Options
export type Config = config.Config
export type Settings = config.Settings

function arc.layout(tuning: Tuning, label: string): ({ read [number]: layouts.Panel }, unknown?) -> ()
  return function(panels: { read [number]: layouts.Panel }, options: unknown?): ()
    local chosen = tuning
    if options ~= nil then
      chosen = config.tuning.resolve(options, tuning, label)
    end
    local widths: { number } = {}
    for index = 1, #panels do
      local panel = panels[index]
      widths[index] = panel.width or 0
    end
    for index, pose in ipairs(geometry.poses(widths, chosen)) do
      panels[index]:setPose(pose)
    end
  end
end

arc.definition = configured.create<<Config, Settings>>({
  name = 'layout/arc',
  schema = config.schema,
  requires = { layouts = layouts.capability },
  init = function(context: plugin.Context, settings: Settings, _publish: plugin.Publisher): ()
    local service: layouts.Service = context:require(layouts.capability)
    service:register(context, { name = settings.layout, apply = arc.layout(settings.tuning, 'layout/arc') })
  end,
}).definition

return table.freeze(arc)
