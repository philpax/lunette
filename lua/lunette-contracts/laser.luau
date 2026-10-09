-- A laser owns a pointer and, unless one is supplied, a native seat, so `attach` takes an owner. `attach` raises
-- when another owner holds a hand.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-contracts/interaction'
local vocabulary = require '@lunette-contracts/vocabulary'

local laser = {}

export type Owner = plugin.Owner
export type Hand = 'left' | 'right'
export type Input = interaction.Input
export type Surface = vocabulary.Surface
export type Color = { read [number]: number }

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
  read pointer: interaction.Pointer,
  read dead: boolean,
  read destroy: (Laser) -> boolean,
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  -- Answers a laser for each hand, left first: the owner's own, or a new one for a free hand.
  read attach: (Service, Owner, Options?) -> { Laser },
  read update: (Service, { read [number]: Surface }) -> (),
  read draw: (Service, Pass) -> (),
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/laser', version = 1 }

laser.capability = capability

return laser
