-- Decouples grab handlers from the placement consumers that update saved poses.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'

local drops = {}

export type Owner = plugin.Owner
export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer

export type Drop = {
  read surface: Surface,
  read pointer: Pointer,
}

export type Listener = {
  read run: (Drop) -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read onDropped: (Service, Owner, Listener) -> plugin.Effect,
  read emit: (Service, Owner, Drop) -> (),
}

export type Capability = plugin.Capability<Service>

drops.capability = plugin.capability<<Service>> { name = 'lunette/drops', version = 1 }

return drops
