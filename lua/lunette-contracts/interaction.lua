-- The interaction service contract.
--
-- Pure picking, scrolling, and pose-store operations stay ordinary methods.
-- Creating a pointer is owner-scoped because the provider owns its pointer
-- registry and the native sinks a pointer can drive.

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

export type PointerOptions = {
  read seat: lunette.Seat?,
  read tuning: Tuning?,
}

export type Service = {
  read TUNING: Tuning,
  read POSE_PROPERTY: string,
  read pick: (Service, { Surface }, vector, vector, Tuning?) -> (Surface?, number?, number?, number?),
  read scrollDelta: (Service, number, number, number?, Tuning?) -> (number, number),
  read storePose: (Service, Surface) -> boolean,
  read restorePose: (Service, Surface) -> boolean,
  read newPointer: (Service, Owner, PointerOptions?) -> Pointer,
  read pointers: (Service) -> { Pointer },
  read focused: (Service) -> (lunette.Seat?, lunette.Sink?),
  read setFocus: (Service, lunette.Seat?, lunette.Sink?) -> (),
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability('lunette/interaction', 1, function(value: Service): Service
  return value
end)

interaction.capability = capability

return interaction
