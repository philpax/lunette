-- Window placement properties resolve from ordered sources. The default precedence is defined in vocabulary.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'
local build = require '@lunette-plugins/rules/service'

export type Settings = build.Settings
export type Service = rules.Service

export type Config = {
  read precedence: number?,
}

return plugin.provider<<Config, Settings, Service>> {
  name = 'rules',
  capability = rules.capability,
  defaults = { precedence = vocabulary.PRECEDENCE.rules },
  build = build,
}
