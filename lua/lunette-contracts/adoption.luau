-- Scoped window adoption. Disposing a start releases its subscriptions and placements without closing windows.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'

export type Owner = plugin.Owner
export type Properties = rules.Resolved
export type Options = {
  read defaults: Properties?,
  read filter: ((lunette.Window) -> boolean)?,
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read install: (Service, Owner) -> plugin.Effect,
  read start: (Service, Owner, Options?) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

return {
  capability = plugin.capability<<Service>> { name = 'lunette/adoption', version = 1 },
}
