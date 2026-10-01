-- The tags provider. Membership borrows panels without requiring the panels
-- contract. It takes no options.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local create = require '@lunette-plugins/tags/service'

export type Config = {}
export type Settings = {}
export type Service = tags.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'tags',
  capability = tags.capability,
  defaults = {},
  build = function(context: plugin.Context, _settings: Settings): Service
    return create(context)
  end,
}
