-- The surfaces service contract: a broker for the surfaces a pointer can pick. Each owner-scoped offer is a
-- named list called on demand, so it is always this frame's; a list that raises contributes nothing. See
-- docs/dev/lua-api.md#frame-and-surfaces.

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
