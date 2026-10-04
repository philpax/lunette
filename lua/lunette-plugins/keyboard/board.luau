-- Types used by keyboard provider hooks.
local keyboard = require '@lunette-contracts/keyboard'
local layout = require '@lunette-plugins/keyboard/layout'

local board = {}

export type RenderedKey = layout.RenderedKey
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
  read style: keyboard.Style,
  read held: boolean,
  read hovered: boolean,
}

export type Press = (Board, RenderedKey, Pointer) -> ()

-- Runs for every pressed key, including action keys.
export type OnKey = (Board, RenderedKey, Pointer, Press) -> ()

export type Paint = (Pass, RenderedKey, KeyState) -> ()

-- Runs for each key after the keyboard plate is drawn.
export type DrawKey = (Pass, RenderedKey, KeyState, Paint) -> ()

return board
