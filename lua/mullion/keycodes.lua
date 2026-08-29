-- The physical keyboard: where the keys are, and which of them are modifiers.
--
-- An evdev keycode names a position on a keyboard and not a letter. Keycode
-- 30 is the first key of the home row on every layout, and what it types
-- belongs to the layout. The keycodes here name positions, and a seat's
-- keymap names letters. Naming a key by position stays accurate for a user
-- who is not on QWERTY, and lunette already obtains the letters from a
-- seat's keymap.
--
-- Separate from `mullion.keyboard` because it is a different thing: that
-- module is a widget, and this is a description of a keyboard. A
-- configuration binding a key uses the names here and does not need the
-- widget.
--
-- The module holds no state and starts nothing, so it installs no teardown
-- hook. A reload leaves nothing behind.

local lunette = require '@lunette'

local keycodes = {}

-- One key in a row: a code, and optionally a label and a width in key units.
export type Key = {
  code: number,
  label: string?,
  width: number?,
}
-- A row of keys.
export type Row = { Key }

-- The keycodes with names of their own, for a caller that presses one
-- without memorising evdev.
keycodes.SHIFT = 42
keycodes.CAPS_LOCK = 58
keycodes.BACKSPACE = 14
keycodes.ENTER = 28
keycodes.SPACE = 57

-- Which keycodes are modifiers, and which modifier each is.
--
-- A key here latches and sends nothing. The names are the set
-- `sink:modifiers` takes, and the set passes on unchanged.
keycodes.MODIFIERS = {
  [42] = 'shift',
  [54] = 'shift',
  [29] = 'control',
  [97] = 'control',
  [56] = 'alt',
  [100] = 'mod5',
  [125] = 'logo',
  [58] = 'capsLock',
}

-- The modifiers that stay on until pressed again. A modifier not in this set
-- clears after the next key.
local locks: { [string]: boolean } = { capsLock = true }
keycodes.LOCKS = locks

-- The order modifiers are reported in. A fixed order keeps the order a
-- client receives independent of table iteration order.
--
-- The order is requested, not listed. The set is the runtime's. A copy here
-- would go stale the moment a modifier is added: `seat:setModifiers` would
-- refuse a name the runtime dropped, or omit a name the runtime added.
keycodes.MODIFIER_ORDER = lunette.modifierNames()

-- Where the keys are, in evdev keycodes, one array per row.
--
-- `width` is in key units and defaults to one. `label` sets the text drawn
-- when a key types a character that has no legend, such as `\r` for enter.
--
-- This is a compact ANSI arrangement and the default layout.
-- `mullion.keyboard` uses it unless a configuration passes its own rows, and
-- that is the full extent of the customisation offered.
keycodes.ROWS = {
  {
    { code = 41 },
    { code = 2 },
    { code = 3 },
    { code = 4 },
    { code = 5 },
    { code = 6 },
    { code = 7 },
    { code = 8 },
    { code = 9 },
    { code = 10 },
    { code = 11 },
    { code = 12 },
    { code = 13 },
    { code = 14, label = 'bksp', width = 2 },
  },
  {
    { code = 15, label = 'tab', width = 1.5 },
    { code = 16 },
    { code = 17 },
    { code = 18 },
    { code = 19 },
    { code = 20 },
    { code = 21 },
    { code = 22 },
    { code = 23 },
    { code = 24 },
    { code = 25 },
    { code = 26 },
    { code = 27 },
    { code = 43, width = 1.5 },
  },
  {
    { code = 58, label = 'caps', width = 1.75 },
    { code = 30 },
    { code = 31 },
    { code = 32 },
    { code = 33 },
    { code = 34 },
    { code = 35 },
    { code = 36 },
    { code = 37 },
    { code = 38 },
    { code = 39 },
    { code = 40 },
    { code = 28, label = 'enter', width = 2.25 },
  },
  {
    { code = 42, label = 'shift', width = 2.25 },
    { code = 44 },
    { code = 45 },
    { code = 46 },
    { code = 47 },
    { code = 48 },
    { code = 49 },
    { code = 50 },
    { code = 51 },
    { code = 52 },
    { code = 53 },
    { code = 54, label = 'shift', width = 2.75 },
  },
  {
    { code = 29, label = 'ctrl', width = 1.25 },
    { code = 125, label = 'logo', width = 1.25 },
    { code = 56, label = 'alt', width = 1.25 },
    { code = 57, label = 'space', width = 6.25 },
    { code = 100, label = 'altgr', width = 1.25 },
    { code = 97, label = 'ctrl', width = 1.25 },
  },
} :: { Row }

return keycodes
