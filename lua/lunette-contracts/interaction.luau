-- Owner-scoped pointers. A provider emits a drop through lunette/drops when a grab ends, because pose memory and the
-- arrangement save hear drops only there.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'

local interaction = {}

export type Owner = plugin.Owner
export type Tuning = vocabulary.Tuning
export type TuningOverride = {
  read reach: number?,
  read grabDeadZone: number?,
  read scrollScale: number?,
  read scrollDeadZone: number?,
  read reachScale: number?,
  read reachMinimum: number?,
  read reachMaximum: number?,
  read resizeMinimum: number?,
  read resizeMaximum: number?,
}
export type Input = vocabulary.Input
export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer
export type PointerEvent = vocabulary.PointerEvent
export type CancelReason = vocabulary.CancelReason

export type ButtonState = vocabulary.ButtonState
export type Push = vocabulary.Push
export type Haptic = vocabulary.Haptic

-- Pointer:vibrate answers false for a pointer made without `vibrate`.
export type PointerOptions = {
  read seat: lunette.Seat?,
  read tuning: TuningOverride?,
  read vibrate: ((Haptic) -> boolean)?,
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read newPointer: (Service, Owner, PointerOptions?) -> Pointer,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/interaction', version = 2 }

interaction.capability = capability

return interaction
