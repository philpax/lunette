-- Registers a layout that arranges panels on an arc. Apply options merge over the registered tuning.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'
local geometry = require '@lunette-plugins/layout/arc/geometry'

local arc = {}

export type Tuning = geometry.Tuning

local config = require '@lunette-plugins/layout/arc/config'
local configured = require '@lunette-plugin/configured'

export type Options = config.Options
export type Config = config.Config
export type Settings = config.Settings

arc.requires = table.freeze { layouts = layouts.capability } :: plugin.Declaration

-- The layout validates merged call options, then poses the panels.
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

local function configuredFor(label: string): configured.Configured<Config, Settings>
  return configured.create<<Config, Settings>> {
    name = label,
    schema = config.schema,
    requires = arc.requires,
    init = function(context: plugin.Context, settings: Settings, _publish: plugin.Publisher): ()
      local service: layouts.Service = context:require(layouts.capability)
      service:register(context, { name = settings.layout, apply = arc.layout(settings.tuning, label) })
    end,
  }
end

local NAME = 'layout/arc'
arc.definition = configuredFor(NAME).definition

function arc.define(fields: Config & { read name: string? }): plugin.Definition<Config>
  if type(fields) ~= 'table' then
    error('plugin ' .. NAME .. ': define takes a table of options, not a ' .. type(fields), 2)
  end
  local given = table.clone((fields :: unknown) :: { [string]: unknown })
  local label = given.name
  given.name = nil
  if label == nil then
    label = NAME
  elseif type(label) ~= 'string' or label == '' then
    error('plugin ' .. NAME .. ': define names a definition with a non-empty string, not ' .. tostring(label), 2)
  end
  return configuredFor(label :: string).define((given :: unknown) :: Config & { read name: string? })
end

return table.freeze(arc)
