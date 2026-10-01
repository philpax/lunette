-- The interaction service contract.
--
-- Creating a pointer is owner-scoped because the provider owns its pointer
-- registry and the native sinks a pointer can drive. A pointer is driven
-- frame by frame with update, or through its primitives, and it presses,
-- scrolls, grabs, and carries the surfaces it is given.
--
-- A provider of this contract emits a drop through lunette/drops whenever a
-- grab ends while it is live, and gives keyboard focus through lunette/focus.
-- Pose memory, the arrangement save, and the arrangement of unplaced windows
-- hear drops only through lunette/drops, so a replacement that does not emit
-- them loses all three without an error.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local vocabulary = require '@lunette-contracts/vocabulary'

local interaction = {}

export type Owner = owner.Owner
export type Tuning = vocabulary.Tuning
export type Input = vocabulary.Input
export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer

export type ButtonState = vocabulary.ButtonState
export type Push = vocabulary.Push
export type Haptic = vocabulary.Haptic

-- What newPointer takes. `vibrate` pulses the device that drives the
-- pointer, and is what Pointer:vibrate calls; a pointer made without one
-- answers false. The laser supplies it for the controller of its hand.
export type PointerOptions = {
  read seat: lunette.Seat?,
  read tuning: Tuning?,
  read vibrate: ((Haptic) -> boolean)?,
}

export type Service = {
  read TUNING: Tuning,
  read newPointer: (Service, Owner, PointerOptions?) -> Pointer,
  read pointers: (Service) -> { Pointer },
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/interaction', schema = 1 }

interaction.capability = capability

return interaction
