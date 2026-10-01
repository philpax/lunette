-- The surfaces service contract.
--
-- A broker for the surfaces a pointer can pick. A plugin offers a named list
-- that the broker calls whenever the surfaces are asked for, so the list is
-- always this frame's. An offer is owner-scoped: it lasts until the returned
-- effect is disposed or its owner unloads. A name names one offer, and
-- offering a name that is already offered raises.
--
-- all answers every offer's surfaces, offers in registration order. Each list
-- runs under its own protected call; a list that raises, or answers something
-- other than a table, is reported through lunette.reportError and contributes
-- nothing.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local surfaces = {}

export type Owner = owner.Owner
export type Surface = surface.Surface

export type Offer = {
  read name: string,
  read list: () -> { Surface },
}

export type Service = {
  read offer: (Service, Owner, Offer) -> plugin.Effect,
  read all: (Service) -> { Surface },
}

export type Capability = plugin.Capability<Service>

surfaces.capability = plugin.capability<<Service>> { name = 'lunette/surfaces', schema = 1 }

return surfaces
