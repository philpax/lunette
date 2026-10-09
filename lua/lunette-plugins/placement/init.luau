-- See docs/dev/lua-api.md#rules-and-placement for the placement options and hook.
local config = require '@lunette-plugins/placement/config'
local schema = require '@lunette-plugin/schema'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local build = require '@lunette-plugins/placement/service'

export type Service = placement.Service
export type Properties = placement.Properties
export type PanelOptionsBase = build.PanelOptionsBase
export type PanelOptions = build.PanelOptions
export type Settings = config.Settings
export type Config = config.Config

return plugin.provider<<Config, Settings, Service>> {
  name = 'placement',
  capability = placement.capability,
  requires = {
    panels.capability,
    rules.capability,
    tags.capability,
  },
  schema = config :: schema.Schema<Config, Settings>,
  build = build.build,
}
