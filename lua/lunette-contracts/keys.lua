-- Keyboard vocabulary: what the native seat and sink API's evdev codes are
-- called, which of them are modifiers, and how LÖVR's desktop key names map
-- onto them.
--
-- An evdev keycode names a position on a keyboard and not a letter. Keycode
-- 30 is the first key of the home row on every layout, and what it types
-- belongs to the layout. The names here name positions, and a seat's keymap
-- names letters.
--
-- The names and codes are the runtime's: `lunette.keyCodes()` answers them,
-- and `lunette.lockingModifierNames()` and `lunette.modifierNames()` answer
-- the modifier sets. A copy here would go stale the moment the runtime's set
-- changed. What this module adds is policy several consumers agree on: which
-- key latches which modifier, and the LÖVR translation.
--
-- The module holds no state and starts nothing, so a reload leaves nothing
-- behind.

local lunette = require '@lunette'

local keys = {}

export type Codes = { [lunette.KeyName]: number }

-- Every named key's evdev code, such as `keys.CODES.leftShift`. Indexing it
-- with a name the runtime does not know is a type error.
local codes: Codes = table.freeze(lunette.keyCodes())
keys.CODES = codes

-- Which modifier each modifier key latches, by evdev code.
--
-- A key here latches and sends nothing on an on-screen keyboard. The names are
-- the set `sink:modifiers` takes. Right alt is `mod5`, the level-three shift
-- that AltGr selects on the layouts that have one.
local modifierKeys: { [number]: string } = {
  [codes.leftShift] = 'shift',
  [codes.rightShift] = 'shift',
  [codes.leftCtrl] = 'control',
  [codes.rightCtrl] = 'control',
  [codes.leftAlt] = 'alt',
  [codes.rightAlt] = 'mod5',
  [codes.leftMeta] = 'logo',
  [codes.capsLock] = 'capsLock',
}
keys.MODIFIER_KEYS = table.freeze(modifierKeys)

-- The modifiers that stay on until pressed again. A modifier not in this set
-- clears after the next key.
local locks: { [string]: boolean } = {}
for _, name in ipairs(lunette.lockingModifierNames()) do
  locks[name] = true
end
keys.LOCKS = table.freeze(locks)

-- The order modifiers are reported in. A fixed order keeps the order a client
-- receives independent of table iteration order.
keys.MODIFIER_ORDER = table.freeze(lunette.modifierNames())

-- LÖVR's names for the desktop keys that type no text, as evdev codes. A
-- consumer forwarding `lovr.keypressed` to a sink looks a key up here, and
-- asks the seat's keymap for any key that types a character.
local fromLovr: { [string]: number } = {
  backspace = codes.backspace,
  ['return'] = codes.enter,
  kpenter = codes.enter,
  escape = codes.escape,
  tab = codes.tab,
  up = codes.up,
  down = codes.down,
  left = codes.left,
  right = codes.right,
  home = codes.home,
  ['end'] = codes['end'],
  pageup = codes.pageUp,
  pagedown = codes.pageDown,
  delete = codes.delete,
  insert = codes.insert,
}
keys.FROM_LOVR = table.freeze(fromLovr)

-- A modifier and the LÖVR keys that hold it.
export type LovrModifier = {
  read keys: { KeyCode },
  read modifier: string,
}

-- The modifiers a desktop keyboard holds, by the LÖVR keys that hold them.
-- Shift is not listed: typed text reaches a sink through the seat's stroke for
-- each character, and that stroke carries its own shift.
local lovrModifiers: { LovrModifier } = {
  { keys = { 'lctrl', 'rctrl' }, modifier = 'control' },
  { keys = { 'lalt', 'ralt' }, modifier = 'alt' },
  { keys = { 'lgui', 'rgui' }, modifier = 'logo' },
}
keys.LOVR_MODIFIERS = table.freeze(lovrModifiers)

return keys
