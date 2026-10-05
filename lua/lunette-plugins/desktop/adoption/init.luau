-- Installs native pose restoration and adopts eligible windows as panels with configured default tags.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local config = require '@lunette-plugins/desktop/adoption/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { adoption = adoption.capability }

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/adoption',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local service: adoption.Service = context:require(adoption.capability)
    service:install(context)
    service:start(context, { defaults = { tags = settings.tags }, filter = settings.filter })
  end,
}).definition
