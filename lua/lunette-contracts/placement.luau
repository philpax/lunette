-- Placement resolves window properties through rules, creates the panel, and joins the named tags.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'

local placement = {}

export type Owner = plugin.Owner
export type Properties = rules.Resolved

-- Missing properties resolve through rules; defaults fill properties that remain unset.
export type Request = {
  read window: lunette.Window,
  read properties: Properties?,
  read defaults: Properties?,
}

export type Placement = {
  read panel: panels.WindowPanel,
  read properties: Properties,
}

export type PlacedListener = {
  read run: (Placement) -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read place: (Service, Owner, Request) -> (panels.WindowPanel, Properties, plugin.Effect),
  read placed: (Service) -> { Placement },
  read onPlaced: (Service, Owner, PlacedListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

placement.capability = plugin.capability<<Service>> { name = 'lunette/placement', schema = 1 }

return placement
