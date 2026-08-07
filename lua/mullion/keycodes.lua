-- The physical keyboard: where the keys are, and which of them are modifiers.
--
-- An evdev keycode names a position on a keyboard and not a letter. Keycode 30
-- is the first key of the home row on every layout, and what it types is the
-- layout's business — so this file says where the keys are and a seat's keymap
-- says what they are. That division is the only one that does not lie to a user
-- who is not on QWERTY, and lunette already knows the truth.
--
-- Separate from `mullion.keyboard` because it is a different thing: that module
-- is a widget, and this is a description of a keyboard. A configuration binding
-- a key wants the names here without wanting the widget.
--
-- This module holds no state and starts nothing, so it registers no teardown
-- hook: there is nothing a reload could leave behind.

local keycodes = {}

-- The keycodes with names of their own, for a caller that wants to press one
-- without knowing evdev by heart.
keycodes.SHIFT = 42
keycodes.CAPS_LOCK = 58
keycodes.BACKSPACE = 14
keycodes.ENTER = 28
keycodes.SPACE = 57

-- Which keycodes are modifiers, and which modifier each is.
--
-- A key here latches rather than sending. The names are `sink:modifiers`'s, so
-- the set is passed on unchanged rather than translated.
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

-- The modifiers that stay on until pressed again, rather than clearing after
-- the next key.
keycodes.LOCKS = { capsLock = true }

-- The order modifiers are reported in, so that what a client is told does not
-- depend on the order a table happened to be walked in.
keycodes.MODIFIER_ORDER =
  { 'shift', 'capsLock', 'control', 'alt', 'numLock', 'mod3', 'logo', 'mod5' }

-- Where the keys are, in evdev keycodes, one array per row.
--
-- `width` is in key units and defaults to one. `label` is what is drawn when a
-- key types nothing a legend could show — a keymap answers `\r` for enter,
-- which is not something to draw on a key.
--
-- This is a compact ANSI arrangement. It is a starting point rather than a
-- claim: a configuration wanting a different one passes its own rows to
-- `mullion.keyboard`, which is the whole extent of the customisation offered.
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
}

return keycodes
