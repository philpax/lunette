-- The physical source's native delivery policy: printable keys wait for committed text, and the XKB keypad rule.
local lunette = require '@lunette'
local keys = require '@lunette-contracts/keys'

local physical = {}

export type NativePolicy = 'activation' | 'text' | 'unavailable'

local codes = keys.CODES

-- Physical native input for these keys waits for committed text unless it is a command chord.
local printable: { [number]: boolean } = {}
for _, name: lunette.KeyName in
  {
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'l',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's',
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
    'digit0',
    'digit1',
    'digit2',
    'digit3',
    'digit4',
    'digit5',
    'digit6',
    'digit7',
    'digit8',
    'digit9',
    'space',
    'grave',
    'minus',
    'equal',
    'leftBrace',
    'rightBrace',
    'backslash',
    'semicolon',
    'apostrophe',
    'comma',
    'dot',
    'slash',
    'keypad0',
    'keypad1',
    'keypad2',
    'keypad3',
    'keypad4',
    'keypad5',
    'keypad6',
    'keypad7',
    'keypad8',
    'keypad9',
    'keypadDot',
    'keypadSlash',
    'keypadAsterisk',
    'keypadMinus',
    'keypadPlus',
    'keypadEqual',
  } :: { lunette.KeyName }
do
  printable[codes[name]] = true
end
table.freeze(printable)

-- The keys whose level depends on NumLock.
local keypad: { [number]: boolean } = {}
for _, name: lunette.KeyName in
  {
    'keypad0',
    'keypad1',
    'keypad2',
    'keypad3',
    'keypad4',
    'keypad5',
    'keypad6',
    'keypad7',
    'keypad8',
    'keypad9',
    'keypadDot',
  } :: { lunette.KeyName }
do
  keypad[codes[name]] = true
end
table.freeze(keypad)

function physical.nativePolicy(
  code: number,
  modifiers: { read [number]: lunette.ModifierName },
  snapshot: keys.PhysicalModifiers?
): NativePolicy
  if keys.commandChord(modifiers) then
    return 'activation'
  end
  if keypad[code] then
    if snapshot == nil then
      return 'unavailable'
    end
    -- XKB's PC KEYPAD type leaves Shift alone at the base level, not the numeric level.
    return if snapshot.numLock and not snapshot.shift then 'text' else 'activation'
  end
  return if printable[code] then 'text' else 'activation'
end

local FIELDS: { [string]: boolean } =
  { shift = true, control = true, alt = true, logo = true, capsLock = true, numLock = true }
table.freeze(FIELDS)

function physical.validate(value: unknown): string?
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    return 'the physical modifier snapshot is a plain table'
  end
  local raw = value :: { [unknown]: unknown }
  for name, enabled in raw do
    if type(name) ~= 'string' or not FIELDS[name] then
      return 'the physical modifier snapshot contains only shift, control, alt, logo, capsLock, and numLock'
    end
    if type(enabled) ~= 'boolean' then
      return 'the physical modifier snapshot fields are booleans'
    end
  end
  for name in FIELDS do
    if type(raw[name]) ~= 'boolean' then
      return 'the physical modifier snapshot requires shift, control, alt, logo, capsLock, and numLock booleans'
    end
  end
  return nil
end

-- Callers validate first.
function physical.snapshot(value: keys.PhysicalModifiers): keys.PhysicalModifiers
  return table.freeze {
    shift = value.shift,
    control = value.control,
    alt = value.alt,
    logo = value.logo,
    capsLock = value.capsLock,
    numLock = value.numLock,
  }
end

return physical
