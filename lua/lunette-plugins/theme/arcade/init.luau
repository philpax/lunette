-- Registers the Arcade theme with the theme catalog. It is an ordinary plugin, so disabling it removes the choice.

local plugin = require '@lunette-plugin'
local themes = require '@lunette-contracts/themes'
local preset = require '@lunette-plugins/theme/arcade/preset'

export type Config = {}
export type Settings = {}

local definition = plugin.consumer<<Config, Settings>>({
  name = 'theme/arcade',
  requires = { themes.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local catalog: themes.Service = context:require(themes.capability)
    catalog:register(context, { name = 'arcade', label = 'Arcade', order = 3, theme = preset })
  end,
}).definition

return table.freeze { definition = definition, preset = preset }
