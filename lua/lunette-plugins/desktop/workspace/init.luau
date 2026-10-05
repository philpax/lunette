-- Holds the selected workspace tag so entry startup order does not matter.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'

local config = require '@lunette-plugins/desktop/workspace/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { tags = tags.capability }

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/workspace',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local service: tags.Service = context:require(tags.capability)
    local tag = service:hold(context, { name = settings.name, selected = true })
    tag:setSelected(context, { selected = true })
  end,
}).definition
