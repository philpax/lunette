-- This module maps LÖVR key names to evdev codes and defines shared modifier ordering.

local lunette = require '@lunette'

local keys = {}

export type Codes = { [lunette.KeyName]: number }

local codes: Codes = table.freeze(lunette.keyCodes())
keys.CODES = codes

-- Right Alt maps to `mod5`, the level-three modifier used by AltGr.
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

-- Locking modifiers stay active until pressed again. Other modifiers clear after the next key.
local locks: { [string]: boolean } = {}
for _, name in ipairs(lunette.lockingModifierNames()) do
  locks[name] = true
end
keys.LOCKS = table.freeze(locks)

-- Modifier order is stable and does not depend on table iteration.
keys.MODIFIER_ORDER = table.freeze(lunette.modifierNames())

-- LÖVR key names for non-text keys map to evdev codes. The seat keymap handles keys that type characters.
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

export type LovrModifier = {
  read keys: { KeyCode },
  read modifier: string,
}

-- Shift is omitted because the seat stroke carries it for each character.
local lovrModifiers: { LovrModifier } = {
  { keys = { 'lctrl', 'rctrl' }, modifier = 'control' },
  { keys = { 'lalt', 'ralt' }, modifier = 'alt' },
  { keys = { 'lgui', 'rgui' }, modifier = 'logo' },
}
keys.LOVR_MODIFIERS = table.freeze(lovrModifiers)

export type HeldQuery = {
  read isDown: (KeyCode) -> boolean,
  read shift: boolean,
}

-- Held modifiers follow `LOVR_MODIFIERS` order, followed by Shift when requested and held.
function keys.heldModifiers(query: HeldQuery): { string }
  local held: { string } = {}
  for _, entry in ipairs(lovrModifiers) do
    for _, name in ipairs(entry.keys) do
      if query.isDown(name) then
        held[#held + 1] = entry.modifier
        break
      end
    end
  end
  if query.shift and (query.isDown 'lshift' or query.isDown 'rshift') then
    held[#held + 1] = 'shift'
  end
  return held
end

return keys
