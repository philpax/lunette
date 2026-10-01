-- The placement service contract.
--
-- Placement turns a window into a panel: it resolves the window's properties
-- through lunette/rules, maps them to the panel's options, makes the panel,
-- and joins the tags the properties name. It is the one component that
-- depends on rules, panels, and tags, so rules depends on neither of the
-- others, and a configuration that wants another mapping, such as one that
-- forwards a property of its own to the panel, replaces placement alone.
--
-- place is owner-scoped and answers the placement effect; disposing it, or
-- the owner unloading, removes the panel, its tag memberships, and the holds
-- on the tags placement made. A placement whose panel is removed by other
-- means ends with it. The properties are the window's resolved properties,
-- or the ones the request gives, with the request's defaults filling in what
-- neither names. A resolved `hidden` of true hides the panel for as long as
-- the placement lasts. A tag named by a string is held, and made when no
-- tag of that name exists, so the tag lasts while any placement or other
-- holder keeps it.
--
-- placed answers every live placement, in the order the windows were placed,
-- with the properties each was placed with. onPlaced listeners hear each
-- placement once it is made, whoever made it, so a consumer can react to
-- placement with the resolved properties. A listener is owner-scoped, runs
-- under its own protected call, and its error is reported through
-- lunette.reportError without undoing the placement.

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
