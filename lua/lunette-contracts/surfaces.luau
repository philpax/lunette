-- Offers are owner-scoped and queried on demand each frame. A failing offer contributes no surfaces.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'

local surfaces = {}

export type Owner = plugin.Owner
export type Surface = vocabulary.Surface

export type Offer = {
  read name: string,
  read list: () -> { Surface },
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read offer: (Service, Owner, Offer) -> plugin.Effect,
  read all: (Service) -> { Surface },
}

export type Capability = plugin.Capability<Service>

surfaces.capability = plugin.capability<<Service>> { name = 'lunette/surfaces', version = 1 }

return surfaces
