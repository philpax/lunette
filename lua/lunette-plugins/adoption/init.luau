-- The scoped adoption provider. `precedence` is the native pose source's default, by default
-- vocabulary.PRECEDENCE.native.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local rules = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'
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
    placement = placement.capability,
    rules = rules.capability,
  },
  defaults = { precedence = vocabulary.PRECEDENCE.native },
  build = build,
}
