-- The scoped adoption provider.
--
-- `precedence` is the precedence install registers the native pose source at
-- when it is given none.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local build = require '@lunette-plugins/adoption/service'

export type Settings = build.Settings
export type Service = adoption.Service

-- What a configuration gives: every option optional.
export type Config = {
  read precedence: number?,
}

return plugin.provider<<Config, Settings, Service>> {
  name = 'adoption',
  capability = adoption.capability,
  requires = {
    panels = panels.capability,
    rules = rules.capability,
  },
  defaults = { precedence = 300 },
  build = build,
}
