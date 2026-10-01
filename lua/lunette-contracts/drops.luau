-- The drops service contract: a broker for the end of a grab, so what ends grabs and what reacts to them
-- need not require each other. A provider that moves surfaces for a pointer should emit here, or a dropped
-- window's pose goes unremembered. A decoration carries the kind and source of the panel it moves, so a
-- listener finds the panel through panels:forSource. See docs/dev/lua-api.md#pointers-and-interaction.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local vocabulary = require '@lunette-contracts/vocabulary'

local drops = {}

export type Owner = owner.Owner
export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer

-- One drop: the surface that was let go of and the pointer that held it.
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
