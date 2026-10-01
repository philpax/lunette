-- The laser service contract.
--
-- A laser owns a pointer and, when no seat is supplied, a native seat. Both
-- constructors therefore require the caller owner explicitly. A hand has one
-- laser under attach: attach answers the caller's own lasers, makes them for
-- free hands, and raises when another owner holds a hand. forHand is a query.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local interaction = require '@lunette-contracts/interaction'
local surface = require '@lunette-contracts/surface'

local laser = {}

export type Owner = owner.Owner
export type Hand = 'left' | 'right'
export type Device = 'hand/left/point' | 'hand/right/point' | 'hand/left' | 'hand/right'
export type Input = interaction.Input
export type Surface = surface.Surface
export type Color = { number }

export type Style = {
  read length: number,
  read color: Color,
  read hoverColor: Color,
  read cursorRadius: number,
  read hapticStrength: number,
  read hapticDuration: number,
}

export type Options = {
  read seat: lunette.Seat?,
  read name: string?,
  read readInput: ((Hand) -> Input?)?,
  read tuning: interaction.Tuning?,
  read style: Style?,
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
  read update: (Laser, { Surface }) -> (),
  read draw: (Laser, Pass) -> (),
  read vibrate: (Laser) -> boolean,
  read destroy: (Laser) -> boolean,
}

export type Service = {
  read HANDS: { Hand },
  read DEVICES: { [string]: Device },
  read CONTROLLERS: { [string]: Device },
  read STYLE: Style,
  read new: (Service, Owner, Hand, Options?) -> Laser,
  read attach: (Service, Owner, Options?) -> { Laser },
  read forHand: (Service, Hand) -> Laser?,
  read all: (Service) -> { Laser },
  read update: (Service, { Surface }) -> (),
  read draw: (Service, Pass) -> (),
  read headsetInput: (Service, Hand) -> Input?,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/laser', schema = 1 }

laser.capability = capability

return laser
