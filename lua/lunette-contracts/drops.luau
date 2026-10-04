-- The drops service decouples grab handlers from consumers. Providers emit each completed grab so placement consumers can update saved poses.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local vocabulary = require '@lunette-contracts/vocabulary'

local drops = {}

export type Owner = owner.Owner
export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer

export type Drop = {
  read surface: Surface,
  read pointer: Pointer,
}

export type Listener = {
  read run: (Drop) -> (),
}

export type Service = {
  read onDropped: (Service, Owner, Listener) -> plugin.Effect,
  read emit: (Service, Owner, Drop) -> (),
}

export type Capability = plugin.Capability<Service>

drops.capability = plugin.capability<<Service>> { name = 'lunette/drops', schema = 1 }

return drops
