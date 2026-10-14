-- Supported types for keyboard press and drawing hooks.
local lunette = require '@lunette'
local keyboard = require '@lunette-contracts/keyboard'

-- Key coordinates use metres from the rows' top-left corner, with `y` increasing downward.
export type RenderedKey = {
  read source: keyboard.Key,
  read code: number?,
  read action: keyboard.Action?,
  read modifier: lunette.ModifierName?,
  read legend: string,
  read x: number,
  read y: number,
  read width: number,
  read height: number,
}

-- A style resolved for drawing at the keyboard's current scale.
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

export type Pointer = keyboard.Pointer

export type Board = keyboard.Keyboard & {
  read layer: string,
  read setLayer: (Board, string) -> (),
  read keys: (Board) -> { RenderedKey },
}

-- `held` marks active modifiers and the key for the visible layer.
export type KeyState = {
  read keyboard: Board,
  read pose: Mat4,
  read style: Style,
  read held: boolean,
  read hovered: boolean,
}

export type Press = (Board, RenderedKey, Pointer) -> ()

-- Runs for every pressed key, including action keys.
export type OnKey = (Board, RenderedKey, Pointer, Press) -> ()

export type Paint = (Pass, RenderedKey, KeyState) -> ()

-- Runs for each key after the keyboard plate is drawn.
export type DrawKey = (Pass, RenderedKey, KeyState, Paint) -> ()

return {}
