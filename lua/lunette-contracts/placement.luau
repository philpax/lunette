-- The placement service contract: turns a window into a panel by resolving its properties through
-- lunette/rules, making the panel, and joining the tags the properties name. It alone depends on rules,
-- panels, and tags, so a configuration replaces placement to change the mapping. See
-- docs/dev/lua-api.md#rules-and-placement.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'

local placement = {}

export type Owner = owner.Owner
export type Properties = rules.Resolved

-- What place takes: the window; the properties to place it with, resolved
-- through rules when nil; and defaults for what the properties do not name.
export type Request = {
  read window: lunette.Window,
  read properties: Properties?,
  read defaults: Properties?,
}

-- A live placement: the panel and the properties it was placed with.
export type Placement = {
  read panel: panels.WindowPanel,
  read properties: Properties,
}

export type PlacedListener = {
  read run: (Placement) -> (),
}

export type Service = {
  read place: (Service, Owner, Request) -> (panels.WindowPanel, Properties, plugin.Effect),
  read placed: (Service) -> { Placement },
  read onPlaced: (Service, Owner, PlacedListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

placement.capability = plugin.capability<<Service>> { name = 'lunette/placement', schema = 1 }

return placement
