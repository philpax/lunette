-- The keyboard service contract.
--
-- Keyboard creation is owner-scoped. Key geometry is ordinary data and remains
-- in this contract because consumers need the same public layout vocabulary.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local interaction = require '@lunette-contracts/interaction'
local surface = require '@lunette-contracts/surface'

local keyboard = {}

export type Owner = owner.Owner
export type Surface = surface.Surface
export type HoverSource = string | interaction.Pointer

export type Key = {
  read code: number,
  read label: string?,
  read width: number?,
}

export type KeyRow = { Key }

export type RenderedKey = {
  read code: number,
  read modifier: string?,
  read legend: string,
  read x: number,
  read y: number,
  read width: number,
  read height: number,
}

export type Style = {
  read keyUnit: number,
  read gap: number,
  read plateDepth: number,
  read legendDepth: number,
  read margin: number,
  read plateColor: { number },
  read keyColor: { number },
  read heldColor: { number },
  read hoverColor: { number },
  read legendColor: { number },
  read legendHeight: number,
}

export type Target = () -> (lunette.Seat?, lunette.Sink?)

export type Options = {
  read rows: { KeyRow }?,
  read style: Style?,
  read pose: Mat4?,
  read target: Target?,
}

export type Keyboard = surface.Surface & {
  read pose: Mat4,
  read rows: { KeyRow },
  read style: Style,
  read target: Target,
  read width: number,
  read height: number,
  read visible: boolean,
  read latched: { [string]: boolean },
  read locked: { [string]: boolean },
  read hovered: { [HoverSource]: RenderedKey? },
  read grabbable: boolean,
  read setPose: (Surface, Mat4) -> (),
  read setSize: (Surface, number?, number?) -> (),
  read raycast: (Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read onHover: (Surface, number?, number?, HoverSource?) -> (),
  read onLeave: (Surface, HoverSource?) -> (),
  read onPress: (Surface, number?, number?, unknown?) -> (),
  read setHovered: (Keyboard, RenderedKey?, HoverSource?) -> (),
  read isHovered: (Keyboard, number) -> boolean,
  read setVisible: (Keyboard, boolean) -> (),
  read modifiers: (Keyboard) -> { string },
  read toggleModifier: (Keyboard, string) -> (),
  read keys: (Keyboard) -> { RenderedKey },
  read legendSeat: (Keyboard) -> lunette.Seat?,
  read legendFor: (Keyboard, Key, lunette.Seat?, { string }) -> string,
  read hit: (Keyboard, vector, vector, boolean?) -> (RenderedKey?, number?),
  read pressKey: (Keyboard, number) -> boolean,
  read typeText: (Keyboard, string) -> boolean,
  read draw: (Keyboard, Pass) -> (),
  read destroy: (Keyboard) -> boolean,
  read isHeld: (Keyboard, { string }, string) -> boolean,
  read clearLatched: (Keyboard, lunette.Seat?, lunette.Sink?) -> boolean,
}

export type Service = {
  read STYLE: Style,
  read new: (Service, Owner, Options?) -> Keyboard,
  read all: (Service) -> { Keyboard },
  read draw: (Service, Pass) -> (),
  read keyAt: (Service, { RenderedKey }, number, number) -> RenderedKey?,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability('lunette/keyboard', 1, function(value: Service): Service
  return value
end)

keyboard.capability = capability

return keyboard
