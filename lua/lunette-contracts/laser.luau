-- The laser service contract. A laser owns a pointer and, unless one is supplied, a native seat, so both
-- constructors take an owner. attach holds one laser per hand and raises when another owner holds the
-- hand. The service's update and draw do what each laser's own methods do. See docs/dev/lua-api.md#lasers.

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
  read STYLE: Style,
  read new: (Service, Owner, Hand, Options?) -> Laser,
  read attach: (Service, Owner, Options?) -> { Laser },
  read forHand: (Service, Hand) -> Laser?,
  read all: (Service) -> { Laser },
  read update: (Service, { Surface }) -> (),
  read draw: (Service, Pass) -> (),
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/laser', schema = 1 }

laser.capability = capability

return laser
