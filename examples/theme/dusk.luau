-- Registers Dusk, the standard Dark theme with a warmer palette, beside the shipped themes.

local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local themes = require '@lunette-contracts/themes'
local descriptors = require '@lunette-plugins/theme/descriptors'
local standard = require '@lunette-plugins/theme/standard'

-- A registered theme is complete, so Dusk starts from Dark rather than from the square base.
local dusk = descriptors.resolve(standard.presets.dark, {
  colors = {
    background = { 0.10, 0.05, 0.06, 1 },
    elevatedBackground = { 0.18, 0.09, 0.10, 0.95 },
    focus = { 1, 0.60, 0.25, 1 },
    selection = { 0.55, 0.25, 0.15, 1 },
    pointerHovered = { 1, 0.60, 0.25, 1 },
  },
})

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>>({
  name = 'example/theme/dusk',
  schema = descriptor,
  requires = { themes = themes.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local catalog: themes.Service = context:require(themes.capability)
    catalog:register(context, { name = 'dusk', label = 'Dusk', order = 4, theme = dusk })
  end,
}).definition
