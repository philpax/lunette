-- Membership borrows panels without requiring the panels contract.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local create = require '@self/private/service'

export type Config = {}
export type Settings = {}
export type Service = tags.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'tags',
  capability = tags.capability,
  build = create,
}
