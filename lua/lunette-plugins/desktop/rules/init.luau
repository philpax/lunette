-- Registers the desktop rule list as a source; configured rules replace the default list.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'

local config = require '@lunette-plugins/desktop/rules/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { rules.capability }

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/rules',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local service: rules.Service = context:require(rules.capability)
    service:setRules(context, { rules = settings.rules })
  end,
}
