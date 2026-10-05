-- Membership borrows panels without requiring the panels contract.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local create = require '@lunette-plugins/tags/service'

local config = require '@lunette-plugins/tags/config'

export type Config = config.Config
export type Settings = config.Settings
export type Service = tags.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'tags',
  schema = config,
  capability = tags.capability,
  build = create,
}
