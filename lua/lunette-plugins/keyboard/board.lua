-- The keyboard provider's own view of a keyboard, and its hooks.
--
-- This module holds types only. A hook receives a `Board`, which is the
-- contract's keyboard with the provider's layers and laid-out keys, so a hook
-- written for this provider can switch layers without the contract asking
-- every keyboard to have them.

local keyboard = require '@lunette-contracts/keyboard'
local layout = require '@lunette-plugins/keyboard/layout'

local board = {}

export type RenderedKey = layout.RenderedKey
export type Pointer = keyboard.Pointer

export type Board = keyboard.Keyboard & {
  -- The layer showing, `base` for the rows.
  read layer: string,
  -- Shows the named layer. Raises for a layer the keyboard does not have.
  read setLayer: (Board, string) -> (),
  -- The keys of the layer showing, placed.
  read keys: (Board) -> { RenderedKey },
}

-- How a key is drawn. `pose` is the centre of the key's face, facing out of
-- the keyboard, and `style` is the keyboard's, scaled with it. `held` is true
-- for a latched or locked modifier and for the key of the layer showing.
export type KeyState = {
  read keyboard: Board,
  read pose: Mat4,
  read style: keyboard.Style,
  read held: boolean,
  read hovered: boolean,
}

-- What `onKey`'s default does: sends a key's code, or performs its action.
export type Press = (Board, RenderedKey, Pointer) -> ()

-- The `onKey` hook. It runs for every key a pointer presses, action keys
-- included, and calls `base` to do what the key does by default.
export type OnKey = (Board, RenderedKey, Pointer, Press) -> ()

-- What `drawKey`'s default does: draws the key's face and legend.
export type Paint = (Pass, RenderedKey, KeyState) -> ()

-- The `drawKey` hook. It runs for every key a keyboard draws, after the
-- plate, and calls `base` to draw the default key.
export type DrawKey = (Pass, RenderedKey, KeyState, Paint) -> ()

return board
