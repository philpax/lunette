-- The laser service contract. A laser owns a pointer and, unless one is supplied, a native seat, so both
-- constructors take an owner. attach holds one laser per hand and raises when another owner holds the
-- hand. The service's update and draw do what each laser's own methods do. See docs/dev/lua-api.md#lasers.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-contracts/interaction'
local vocabulary = require '@lunette-contracts/vocabulary'

local laser = {}

export type Owner = plugin.Owner
export type Hand = 'left' | 'right'
export type Device = 'hand/left/point' | 'hand/right/point' | 'hand/left' | 'hand/right'
export type Input = interaction.Input
export type Surface = vocabulary.Surface
export type Color = { read [number]: number }

export type Style = {
  read length: number,
  read color: Color,
  read hoverColor: Color,
  read cursorRadius: number,
  read hapticStrength: number,
  read hapticDuration: number,
}

export type StyleOverride = {
  read length: number?,
  read color: Color?,
  read hoverColor: Color?,
  read cursorRadius: number?,
  read hapticStrength: number?,
  read hapticDuration: number?,
}

-- Cutoffs are in hertz. Betas scale cutoff by unit-direction speed and positional speed in metres per second.
export type Aim = {
  read enabled: boolean,
  read minCutoff: number,
  read derivativeCutoff: number,
  read angularBeta: number,
  read positionBeta: number,
  read resetAfter: number,
}
export type AimOverride = {
  read enabled: boolean?,
  read minCutoff: number?,
  read derivativeCutoff: number?,
  read angularBeta: number?,
  read positionBeta: number?,
  read resetAfter: number?,
}

-- Trigger pressure is a fraction; unlockAngle is in radians, and unlockDistance is in metres.
export type TriggerLock = {
  read enabled: boolean,
  read threshold: number,
  read unlockAngle: number,
  read unlockDistance: number,
}
export type TriggerLockOverride = {
  read enabled: boolean?,
  read threshold: number?,
  read unlockAngle: number?,
  read unlockDistance: number?,
}

export type Options = {
  read aim: AimOverride?,
  read triggerLock: TriggerLockOverride?,
  read seat: lunette.Seat?,
  read name: string?,
  read readInput: ((Hand) -> Input?)?,
  read tuning: interaction.TuningOverride?,
  read style: StyleOverride?,
}

export type Laser = {
  read hand: Hand,
  read device: Device,
  read controller: Device,
  read seat: lunette.Seat,
  read ownsSeat: boolean,
  read readInput: (Hand) -> Input?,
  read pointer: interaction.Pointer,
  read style: Style,
  read input: Input?,
  read dead: boolean,
  read update: (Laser, { read [number]: Surface }) -> (),
  read draw: (Laser, Pass) -> (),
  read vibrate: (Laser) -> boolean,
  read destroy: (Laser) -> boolean,
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read HANDS: { Hand },
  read new: (Service, Owner, Hand, Options?) -> Laser,
  read attach: (Service, Owner, Options?) -> { Laser },
  read forHand: (Service, Hand) -> Laser?,
  read all: (Service) -> { Laser },
  read update: (Service, { read [number]: Surface }) -> (),
  read draw: (Service, Pass) -> (),
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/laser', schema = 1 }

laser.capability = capability

return laser
