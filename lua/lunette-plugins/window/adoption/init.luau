-- Adopts eligible windows using rules and placement providers.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local rules = require '@lunette-contracts/rules'
local build = require '@self/private/service'

export type Service = adoption.Service

return plugin.provider<<{}, {}, Service>> {
  name = 'adoption',
  capability = adoption.capability,
  requires = {
    panels.capability,
    placement.capability,
    rules.capability,
  },
  build = build,
}
