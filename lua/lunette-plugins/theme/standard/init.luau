-- Registers the Dark and Light themes with the theme catalog.

local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local themes = require '@lunette-contracts/themes'
local presets = require '@lunette-plugins/theme/standard/presets'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

local definition = plugin.consumer<<Config, Settings>>({
  name = 'theme/standard',
  schema = descriptor,
  requires = { themes = themes.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local catalog: themes.Service = context:require(themes.capability)
    catalog:register(context, { name = 'dark', label = 'Dark', order = 1, theme = presets.dark })
    catalog:register(context, { name = 'light', label = 'Light', order = 2, theme = presets.light })
  end,
}).definition

return table.freeze { definition = definition, presets = presets }
