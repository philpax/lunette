-- Shared key vocabulary: the runtime's evdev codes, the modifier each modifier key holds, and the host snapshot.

local lunette = require '@lunette'

local keys = {}

export type Codes = { [lunette.KeyName]: number }

-- The host event reports lock state, not whether a lock key is physically held.
export type PhysicalModifiers = {
  read shift: boolean,
  read control: boolean,
  read alt: boolean,
  read logo: boolean,
  read capsLock: boolean,
  read numLock: boolean,
}

local codes: Codes = table.freeze(lunette.keyCodes())
keys.CODES = codes

-- Right Alt maps to `mod5`, the level-three modifier used by AltGr.
local modifierKeys: { [number]: lunette.ModifierName } = {
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

-- Control, logo, and left Alt make a key a command: it activates and commits no text.
function keys.commandChord(modifiers: { read [number]: lunette.ModifierName }): boolean
  for index = 1, #modifiers do
    local name = modifiers[index]
    if name == 'control' or name == 'logo' or name == 'alt' then
      return true
    end
  end
  return false
end

return keys
