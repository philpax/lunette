-- The arc layout: registers a layout with the layouts broker that poses panels
-- on an arc in front of a centre.
--
-- The module answers `definition`, the shipped registration; `define`, which
-- makes another with other defaults; and `requires`, what the registration
-- needs. Its options are `layout`, the name it registers under, and `tuning`,
-- the radius, minimum angular step, total span, gap between panel edges, and
-- centre that `@lunette-plugins/layout/arc/geometry` lays panels out with.
-- The options a caller passes to `layouts:apply` are a tuning of their own,
-- every field optional, merged over the configured one for that call.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'
local geometry = require '@lunette-plugins/layout/arc/geometry'

local arc = {}

export type Tuning = geometry.Tuning

-- A tuning with every field optional: what a configuration and a call give.
export type Options = {
  read radius: number?,
  read step: number?,
  read span: number?,
  read gap: number?,
  read center: { number }?,
}

-- What a configuration gives: every option optional.
export type Config = {
  read layout: string?,
  read tuning: Options?,
}

-- The resolved options.
export type Settings = {
  read layout: string,
  read tuning: Tuning,
}

local DEFAULTS: Settings = {
  layout = 'arc',
  tuning = {
    radius = 1.6,
    step = 0.55,
    span = math.pi * 1.2,
    gap = 0.05,
    center = { 0, 1.5, 0 },
  },
}

arc.requires = table.freeze { layouts = layouts.capability } :: plugin.Declaration

local function resolve(label: string, defaults: Settings, config: unknown): Settings
  local settings = plugin.options { name = label, defaults = defaults, config = config }
  if settings.layout == '' then
    error(string.format('plugin %s: option layout is a non-empty name', label), 0)
  end
  geometry.validate(settings.tuning, label)
  return settings
end

-- The layout function for a tuning: it poses the panels it is given, merging
-- a call's options over the tuning and validating them under `label`.
function arc.layout(tuning: Tuning, label: string): ({ layouts.Panel }, unknown?) -> ()
  return function(panels: { layouts.Panel }, options: unknown?): ()
    local chosen = tuning
    if options ~= nil then
      chosen = plugin.options { name = label, defaults = tuning, config = options }
      geometry.validate(chosen, label)
    end
    local widths: { number } = {}
    for index, panel in ipairs(panels) do
      widths[index] = panel.width or 0
    end
    for index, pose in ipairs(geometry.poses(widths, chosen)) do
      layouts.setPose(panels[index], pose)
    end
  end
end

local function definitionFor(label: string, defaults: Settings): plugin.Definition<Config>
  return plugin.define {
    name = label,
    requires = arc.requires,
    init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
      local settings = resolve(label, defaults, config)
      local service: layouts.Service = context:require(layouts.capability)
      service:register(context, { name = settings.layout, apply = arc.layout(settings.tuning, label) })
    end,
  }
end

local NAME = 'layout/arc'
local defaults = resolve(NAME, DEFAULTS, nil)

arc.definition = definitionFor(NAME, defaults)

-- A definition whose options are `fields` merged over the defaults, named by
-- `fields.name`, which defaults to the module's own.
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
  return definitionFor(label :: string, resolve(label :: string, defaults, given))
end

return table.freeze(arc)
