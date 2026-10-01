-- The interaction service contract: owner-scoped pointers that press, scroll, grab, and carry surfaces.
--
-- A provider must emit a drop through lunette/drops whenever a grab ends and give focus through
-- lunette/focus; pose memory and the arrangement save hear drops only there, so a replacement that does not
-- emit them loses both silently.

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

-- What newPointer takes. `vibrate` is what Pointer:vibrate calls; a pointer made without one answers false.
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
