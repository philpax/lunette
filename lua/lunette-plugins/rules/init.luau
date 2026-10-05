-- Window placement properties resolve from ordered sources. The default precedence is defined in vocabulary.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'
local config = require '@lunette-plugins/rules/config'
local build = require '@lunette-plugins/rules/service'

export type Settings = config.Settings
export type Service = rules.Service
export type Config = config.Config

return plugin.provider<<Config, Settings, Service>> {
  name = 'rules',
  capability = rules.capability,
  schema = config,
  build = build,
}
