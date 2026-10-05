-- Scoped window adoption, separate from installation of placement sources.
--
-- install registers the native-state source on the caller's owner, at the highest precedence. start
-- subscribes before enumerating, skips windows that already have a live panel, and places each window
-- through lunette/placement unless its filter or a resolved `adopt` of false declines it. Disposing the
-- start's effect releases its subscriptions and placements without closing windows. See
-- docs/dev/lua-api.md#rules-and-placement.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local rules = require '@lunette-contracts/rules'
local panels = require '@lunette-contracts/panels'

export type Owner = owner.Owner
export type Properties = rules.Resolved
export type Options = {
  read defaults: Properties?,
  read filter: ((lunette.Window) -> boolean)?,
  read onPlaced: ((panels.WindowPanel, Properties) -> ())?,
}

-- What install takes: the precedence its source is registered at, by default
-- PRECEDENCE, which is vocabulary.PRECEDENCE.native unless configured.
export type InstallOptions = {
  read precedence: number?,
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read PRECEDENCE: number,
  read install: (Service, Owner, InstallOptions?) -> plugin.Effect,
  read start: (Service, Owner, Options?) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

return {
  capability = plugin.capability<<Service>> { name = 'lunette/adoption', schema = 1 },
}
