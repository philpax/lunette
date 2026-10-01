-- The rules provider: window placement policy over panels and tags.
--
-- `precedence` is the precedence a rule set takes when it names none.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local panels = require '@lunette-contracts/panels'
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
  requires = {
    panels = panels.capability,
    tags = tags.capability,
  },
  defaults = { precedence = 100 },
  build = build,
}
