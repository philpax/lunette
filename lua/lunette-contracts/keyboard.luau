-- The keyboard service contract. Key geometry is data here because a configuration writes rows for
-- whichever provider serves it; behaviour, layout, drawing, and layers are the provider's.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'
local theme = require '@lunette-contracts/theme'
local vocabulary = require '@lunette-contracts/vocabulary'

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
  | { read kind: 'chord', read code: number, read modifiers: { read [number]: string } }
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
export type KeyRow = { read [number]: Key }

export type Style = {
  read font: Font,
  read backingRadius: number,
  read keyRadius: number,
  read keyUnit: number,
  read gap: number,
  read plateDepth: number,
  read legendDepth: number,
  read margin: number,
  read plateColor: { read [number]: number },
  read keyColor: { read [number]: number },
  read heldColor: { read [number]: number },
  read hoverColor: { read [number]: number },
  read legendColor: { read [number]: number },
  read legendHeight: number,
}

-- Style options merge over the theme and provider. Radii are measured in metres.
export type StyleOptions = {
  read font: theme.FontSpec?,
  read backingRadius: number?,
  read keyRadius: number?,
  read keyUnit: number?,
  read gap: number?,
  read plateDepth: number?,
  read legendDepth: number?,
  read margin: number?,
  read plateColor: { read [number]: number }?,
  read keyColor: { read [number]: number }?,
  read heldColor: { read [number]: number }?,
  read hoverColor: { read [number]: number }?,
  read legendColor: { read [number]: number }?,
  read legendHeight: number?,
}

export type Target = () -> (lunette.Seat?, lunette.Sink?)

export type VisibilityChange = {
  read visible: boolean,
  read reason: 'show' | 'hide' | 'user-hide' | 'destroy',
}

-- Rows, layers, and style override the provider's for this keyboard. The native-only
-- target adapter never supersedes a focused local receiver. Visibility callbacks belong to the owner.
export type Options = {
  read rows: { read [number]: KeyRow }?,
  read layers: { read [string]: { read [number]: KeyRow } }?,
  read style: StyleOptions?,
  read pose: Mat4?,
  read target: Target?,
  read onVisibilityChanged: ((VisibilityChange) -> ())?,
}

-- A keyboard is a surface an owner places, offers, and draws. Its type repeats
-- the required fields because optional methods on `Surface` make calls ambiguous.
export type Keyboard = {
  read attachFrame: ((Surface, Owner, vocabulary.FrameStyle) -> vocabulary.FrameAttachment)?,
  read kind: nil,
  read dead: boolean,
  read grabbable: boolean,
  read pose: Mat4,
  read width: number,
  read height: number,
  read visible: boolean,
  read raycast: (Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read project: ((Surface, vector, vector) -> (number?, number?, number?))?,
  read onPointer: ((Surface, surface.PointerEvent) -> ())?,
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

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read new: (Service, Owner, Options?) -> Keyboard,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/keyboard', schema = 3 }

keyboard.capability = capability

return keyboard
