-- The interaction service contract.
--
-- Pure picking, scrolling, and pose-store operations stay ordinary methods.
-- Creating a pointer is owner-scoped because the provider owns its pointer
-- registry and the native sinks a pointer can drive.
--
-- Keyboard focus is held. A pointer that gives a seat's keyboard to a sink
-- holds that focus until it is destroyed or its owner unloads, and setFocus
-- holds a focus for its owner until the owner unloads or the returned effect
-- is disposed. When a holder ends, the seat it focused is withdrawn natively
-- and focused stops answering it, unless a later holder has taken that seat.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local vocabulary = require '@lunette-contracts/vocabulary'

local interaction = {}

export type Owner = owner.Owner
export type Tuning = vocabulary.Tuning
export type Input = vocabulary.Input
export type Surface = vocabulary.Surface
export type Grab = vocabulary.Grab
export type Scaling = vocabulary.Scaling
export type Pointer = vocabulary.Pointer

export type ButtonState = vocabulary.ButtonState
export type Push = vocabulary.Push
export type Haptic = vocabulary.Haptic

-- What setFocus gives an owner's focus to: a seat's keyboard and the sink
-- that receives it. A nil sink withdraws the seat's focus.
export type Focus = {
  read seat: lunette.Seat?,
  read sink: lunette.Sink?,
}

-- What scrollDelta converts: a stick deflection on each axis, the frame time
-- it is scaled by, and the tuning whose dead zone and scale apply.
export type Scroll = {
  read x: number,
  read y: number,
  read dt: number?,
  read tuning: Tuning?,
}

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
  read POSE_PROPERTY: string,
  read pick: (Service, { Surface }, vector, vector, Tuning?) -> (Surface?, number?, number?, number?),
  read scrollDelta: (Service, Scroll) -> (number, number),
  read storePose: (Service, Surface) -> boolean,
  read restorePose: (Service, Surface) -> boolean,
  read newPointer: (Service, Owner, PointerOptions?) -> Pointer,
  read pointers: (Service) -> { Pointer },
  read focused: (Service) -> (lunette.Seat?, lunette.Sink?),
  read setFocus: (Service, Owner, Focus) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/interaction', schema = 1 }

interaction.capability = capability

return interaction
