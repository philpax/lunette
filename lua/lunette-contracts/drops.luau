-- The drops service contract.
--
-- A drop is the end of a grab: a pointer let go of a surface it was carrying.
-- The contract is a broker between what ends grabs and what reacts to them, so
-- neither side requires the other. Whatever ends a grab emits a drop here; the
-- desktop's pose memory, the arrangement save, and the arrangement of
-- unplaced windows hear it here.
--
-- A provider of lunette/interaction, or any other plugin that moves surfaces
-- for a pointer, emits a drop through this contract whenever a grab ends while
-- it is live. One that does not emit leaves a dropped window's pose
-- unremembered across a reload and unsaved until quit, and leaves a dragged
-- window in the arrangement it was dragged out of.
--
-- onDropped is owner-scoped: the listener lasts until the returned effect is
-- disposed or its owner unloads. emit names the owner emitting, which must be
-- a live dependent of the provider. Listeners run in registration order, each
-- under its own protected call; a listener that raises is reported through
-- lunette.reportError, and the listeners after it still run.
--
-- The surface in a drop is what the pointer carried. A panel offered as a
-- surface is its own surface; a decoration that moves a panel, such as a
-- title bar, carries the kind and source of the panel it moves, so a listener
-- finds the panel through panels:forSource.

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
