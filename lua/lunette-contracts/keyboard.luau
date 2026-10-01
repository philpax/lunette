-- The keyboard service contract.
--
-- Keyboard creation is owner-scoped, and each owner draws and offers the
-- keyboards it made. Key geometry is ordinary data and remains in this
-- contract, because a configuration writes rows for whichever provider serves
-- it. What a keyboard does with a press, how it lays out and draws its keys,
-- and its layers are the provider's own.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local keyboard = {}

export type Owner = owner.Owner
export type Surface = surface.Surface
export type Pointer = surface.Pointer

-- What a key does other than send its keycode. `hide` hides the keyboard;
-- `layer` shows the named layer, where `base` names the rows; `text` types its
-- text; `chord` sends one key with the named modifiers held, as in ctrl+alt+t;
-- `custom` does nothing by default and is for a hook to give meaning to.
export type Action =
  { read kind: 'hide' }
  | { read kind: 'layer', read layer: string }
  | { read kind: 'text', read text: string }
  | { read kind: 'chord', read code: number, read modifiers: { string } }
  | { read kind: 'custom', read name: string }

-- One key of a row. A key has an evdev `code`, an `action`, or neither, in
-- which case it is a spacer: it takes up room and is neither drawn nor
-- pressed. `width` and `height` are in key units and default to one. `x` is
-- room left empty before the key, in key units, and defaults to zero. `label`
-- is the legend drawn in place of the one the seat's keymap gives.
export type Key = {
  read code: number?,
  read action: Action?,
  read label: string?,
  read width: number?,
  read height: number?,
  read x: number?,
}

-- A row of keys, laid out left to right. A row advances the next one by the
-- height of its shortest key, so a two-unit key reaches into the row below,
-- which leaves a spacer where it lands; an empty row advances by one unit.
export type KeyRow = { Key }

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

-- Style options, each merged over the provider's.
export type StyleOptions = {
  read keyUnit: number?,
  read gap: number?,
  read plateDepth: number?,
  read legendDepth: number?,
  read margin: number?,
  read plateColor: { number }?,
  read keyColor: { number }?,
  read heldColor: { number }?,
  read hoverColor: { number }?,
  read legendColor: { number }?,
  read legendHeight: number?,
}

export type Target = () -> (lunette.Seat?, lunette.Sink?)

-- What `new` takes. `rows`, `layers`, and `style` override the provider's for
-- this keyboard. `target` answers where keys go, by default the focused seat
-- and sink of lunette/focus.
export type Options = {
  read rows: { KeyRow }?,
  read layers: { [string]: { KeyRow } }?,
  read style: StyleOptions?,
  read pose: Mat4?,
  read target: Target?,
}

-- A keyboard is a surface an owner places, offers, and draws. Its width and
-- height cover the widest and tallest of its layers, and `setSize` keeps its
-- proportions. The type states the surface fields a keyboard always has
-- rather than intersecting `Surface`, whose optional methods would make a
-- call through the intersection ambiguous; a keyboard is still a `Surface`.
export type Keyboard = {
  read kind: nil,
  read dead: boolean,
  read grabbable: boolean,
  read pose: Mat4,
  read width: number,
  read height: number,
  read visible: boolean,
  read raycast: (Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read setPose: (Surface, Mat4) -> (),
  read setSize: (Surface, number?, number?) -> (),
  read onHover: (Surface, number?, number?, Pointer) -> (),
  read onLeave: (Surface, Pointer) -> (),
  read onPress: (Surface, number?, number?, Pointer) -> (),
  read setVisible: (Keyboard, boolean) -> (),
  read pressKey: (Keyboard, number) -> boolean,
  read typeText: (Keyboard, string) -> boolean,
  read modifiers: (Keyboard) -> { string },
  read draw: (Keyboard, Pass) -> (),
  read destroy: (Keyboard) -> boolean,
}

export type Service = {
  read new: (Service, Owner, Options?) -> Keyboard,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/keyboard', schema = 1 }

keyboard.capability = capability

return keyboard
