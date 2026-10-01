-- The rules provider: window placement policy as ordered sources.
--
-- `precedence` is the precedence a rule set takes when it names none, by
-- default vocabulary.PRECEDENCE.rules. The provider requires no other
-- contract; lunette/placement turns resolved properties into panels.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'
local build = require '@lunette-plugins/rules/service'

export type Settings = build.Settings
export type Service = rules.Service

-- What a configuration gives: every option optional.
export type Config = {
  read precedence: number?,
}

return plugin.provider<<Config, Settings, Service>> {
  name = 'rules',
  capability = rules.capability,
  defaults = { precedence = vocabulary.PRECEDENCE.rules },
  build = build,
}
