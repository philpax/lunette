-- Adopts eligible windows using rules and placement providers.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local rules = require '@lunette-contracts/rules'
local config = require '@lunette-plugins/adoption/config'
local build = require '@lunette-plugins/adoption/service'

export type Settings = config.Settings
export type Service = adoption.Service
export type Config = config.Config

return plugin.provider<<Config, Settings, Service>> {
  name = 'adoption',
  capability = adoption.capability,
  requires = {
    panels = panels.capability,
    placement = placement.capability,
    rules = rules.capability,
  },
  schema = config,
  build = build,
}
