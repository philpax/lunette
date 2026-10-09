-- The keyboard service contract. Key geometry is data here because a configuration writes rows for whichever
-- provider serves it.

local plugin = require '@lunette-plugin'
local theme = require '@lunette-contracts/theme'
local vocabulary = require '@lunette-contracts/vocabulary'

local keyboard = {}

export type Owner = plugin.Owner
export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer

-- The layer `base` names the rows. A `custom` action does nothing unless a hook handles it.
export type Action =
  { read kind: 'hide' }
  | { read kind: 'layer', read layer: string }
  | { read kind: 'text', read text: string }
  | { read kind: 'chord', read code: number, read modifiers: { read [number]: string } }
  | { read kind: 'custom', read name: string }

-- A key with neither `code` nor `action` is a spacer. Sizes and the `x` gap are in key units. `label` replaces the
-- keymap's legend.
export type Key = {
  read code: number?,
  read action: Action?,
  read label: string?,
  read width: number?,
  read height: number?,
  read x: number?,
}

-- A row advances by its shortest key's height, so a taller key reaches into the row below. An empty row advances by
-- one unit.
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

export type VisibilityChange = {
  read visible: boolean,
  read reason: 'show' | 'hide' | 'user-hide' | 'destroy',
}

-- Rows, layers, and style override the provider's for this keyboard. Visibility callbacks belong to the owner.
export type Options = {
  read rows: { read [number]: KeyRow }?,
  read layers: { read [string]: { read [number]: KeyRow } }?,
  read style: StyleOptions?,
  read pose: Mat4?,
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
  read onPointer: (Surface, vocabulary.PointerEvent) -> (),
  read setPose: (Surface, Mat4) -> (),
  read setSize: (Surface, number?, number?) -> (),
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
