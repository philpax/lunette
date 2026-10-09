-- This module maps LÖVR key names to evdev codes and defines shared modifier ordering.

local lunette = require '@lunette'

local keys = {}

export type Codes = { [lunette.KeyName]: number }

-- The host event reports lock state, not whether a lock key is physically held.
export type PhysicalModifiers = {
  read shift: boolean,
  read control: boolean,
  read alt: boolean,
  read super: boolean,
  read capsLock: boolean,
  read numLock: boolean,
}

export type PhysicalNativePolicy = 'activation' | 'text' | 'unavailable'

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

-- Modifier order is stable and does not depend on table iteration.
keys.MODIFIER_ORDER = table.freeze(lunette.modifierNames())

-- This closed map supplies activations, not inserted text or platform scancodes.
local fromLovr: { [string]: number } = {
  a = codes.a,
  b = codes.b,
  c = codes.c,
  d = codes.d,
  e = codes.e,
  f = codes.f,
  g = codes.g,
  h = codes.h,
  i = codes.i,
  j = codes.j,
  k = codes.k,
  l = codes.l,
  m = codes.m,
  n = codes.n,
  o = codes.o,
  p = codes.p,
  q = codes.q,
  r = codes.r,
  s = codes.s,
  t = codes.t,
  u = codes.u,
  v = codes.v,
  w = codes.w,
  x = codes.x,
  y = codes.y,
  z = codes.z,
  ['0'] = codes.digit0,
  ['1'] = codes.digit1,
  ['2'] = codes.digit2,
  ['3'] = codes.digit3,
  ['4'] = codes.digit4,
  ['5'] = codes.digit5,
  ['6'] = codes.digit6,
  ['7'] = codes.digit7,
  ['8'] = codes.digit8,
  ['9'] = codes.digit9,
  space = codes.space,
  ['return'] = codes.enter,
  tab = codes.tab,
  escape = codes.escape,
  backspace = codes.backspace,
  up = codes.up,
  down = codes.down,
  left = codes.left,
  right = codes.right,
  home = codes.home,
  ['end'] = codes['end'],
  pageup = codes.pageUp,
  pagedown = codes.pageDown,
  insert = codes.insert,
  delete = codes.delete,
  f1 = codes.f1,
  f2 = codes.f2,
  f3 = codes.f3,
  f4 = codes.f4,
  f5 = codes.f5,
  f6 = codes.f6,
  f7 = codes.f7,
  f8 = codes.f8,
  f9 = codes.f9,
  f10 = codes.f10,
  f11 = codes.f11,
  f12 = codes.f12,
  ['`'] = codes.grave,
  ['-'] = codes.minus,
  ['='] = codes.equal,
  ['['] = codes.leftBrace,
  [']'] = codes.rightBrace,
  ['\\'] = codes.backslash,
  [';'] = codes.semicolon,
  ["'"] = codes.apostrophe,
  [','] = codes.comma,
  ['.'] = codes.dot,
  ['/'] = codes.slash,
  kp0 = codes.keypad0,
  kp1 = codes.keypad1,
  kp2 = codes.keypad2,
  kp3 = codes.keypad3,
  kp4 = codes.keypad4,
  kp5 = codes.keypad5,
  kp6 = codes.keypad6,
  kp7 = codes.keypad7,
  kp8 = codes.keypad8,
  kp9 = codes.keypad9,
  ['kp.'] = codes.keypadDot,
  ['kp/'] = codes.keypadSlash,
  ['kp*'] = codes.keypadAsterisk,
  ['kp-'] = codes.keypadMinus,
  ['kp+'] = codes.keypadPlus,
  kpenter = codes.keypadEnter,
  ['kp='] = codes.keypadEqual,
  lctrl = codes.leftCtrl,
  lshift = codes.leftShift,
  lalt = codes.leftAlt,
  lgui = codes.leftMeta,
  rctrl = codes.rightCtrl,
  rshift = codes.rightShift,
  ralt = codes.rightAlt,
  rgui = codes.rightMeta,
  capslock = codes.capsLock,
  scrolllock = codes.scrollLock,
  numlock = codes.numLock,
}
keys.FROM_LOVR = table.freeze(fromLovr)

-- Physical native input for these keys waits for committed text unless it is a command chord.
local printableCodes: { [number]: boolean } = {}
local printableNames = {
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
  '0',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  'space',
  '`',
  '-',
  '=',
  '[',
  ']',
  '\\',
  ';',
  "'",
  ',',
  '.',
  '/',
  'kp0',
  'kp1',
  'kp2',
  'kp3',
  'kp4',
  'kp5',
  'kp6',
  'kp7',
  'kp8',
  'kp9',
  'kp.',
  'kp/',
  'kp*',
  'kp-',
  'kp+',
  'kp=',
}
for _, name in ipairs(printableNames) do
  printableCodes[fromLovr[name]] = true
end
table.freeze(printableCodes)

export type LovrModifier = {
  read keys: { KeyCode },
  read modifier: string,
}

local lovrModifiers: { LovrModifier } = {
  { keys = { 'lctrl', 'rctrl' }, modifier = 'control' },
  { keys = { 'lalt' }, modifier = 'alt' },
  { keys = { 'ralt' }, modifier = 'mod5' },
  { keys = { 'lgui', 'rgui' }, modifier = 'logo' },
}
table.freeze(lovrModifiers)

export type HeldQuery = {
  read isDown: (KeyCode) -> boolean,
  read shift: boolean,
}

-- Held modifiers follow `lovrModifiers` order, followed by Shift when requested and held.
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

local physicalFields: { [string]: boolean } =
  { shift = true, control = true, alt = true, super = true, capsLock = true, numLock = true }
table.freeze(physicalFields)

function keys.validatePhysicalModifiers(value: unknown): string?
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    return 'the physical modifier snapshot is a plain table'
  end
  local raw = value :: { [unknown]: unknown }
  for name, enabled in raw do
    if type(name) ~= 'string' or not physicalFields[name] then
      return 'the physical modifier snapshot contains only shift, control, alt, super, capsLock, and numLock'
    end
    if type(enabled) ~= 'boolean' then
      return 'the physical modifier snapshot fields are booleans'
    end
  end
  for name in physicalFields do
    if type(raw[name]) ~= 'boolean' then
      return 'the physical modifier snapshot requires shift, control, alt, super, capsLock, and numLock booleans'
    end
  end
  return nil
end

function keys.snapshotPhysicalModifiers(value: PhysicalModifiers): PhysicalModifiers
  local invalid = keys.validatePhysicalModifiers(value)
  if invalid then
    error(invalid, 2)
  end
  return table.freeze {
    shift = value.shift,
    control = value.control,
    alt = value.alt,
    super = value.super,
    capsLock = value.capsLock,
    numLock = value.numLock,
  }
end

function keys.physicalModifierNames(value: PhysicalModifiers, isDown: (KeyCode) -> boolean): { string }
  local sidedAlt: { string } = {}
  -- The host flags combine both Alt keys. Only sided Alt remains a delivery-time query.
  if value.alt then
    if isDown 'ralt' then
      sidedAlt[#sidedAlt + 1] = 'mod5'
    end
    if isDown 'lalt' then
      sidedAlt[#sidedAlt + 1] = 'alt'
    end
  end
  return keys.physicalActivationModifiers(value, sidedAlt)
end

function keys.physicalActivationModifiers(value: PhysicalModifiers, requested: { read [number]: string }): { string }
  local result: { string } = {}
  local rightAlt, leftAlt = false, false
  for index = 1, #requested do
    local name = string.lower(requested[index])
    rightAlt = rightAlt or name == 'mod5'
    leftAlt = leftAlt or name == 'alt' or name == 'mod1'
  end
  if value.control then
    result[#result + 1] = 'control'
  end
  if value.alt and (not rightAlt or leftAlt) then
    result[#result + 1] = 'alt'
  end
  if value.alt and rightAlt then
    result[#result + 1] = 'mod5'
  end
  if value.super then
    result[#result + 1] = 'logo'
  end
  if value.shift then
    result[#result + 1] = 'shift'
  end
  if value.capsLock then
    result[#result + 1] = 'capsLock'
  end
  if value.numLock then
    result[#result + 1] = 'numLock'
  end
  return result
end

function keys.commandChord(modifiers: { read [number]: string }): boolean
  for index = 1, #modifiers do
    local name = string.lower(modifiers[index])
    if
      name == 'control'
      or name == 'ctrl'
      or name == 'logo'
      or name == 'super'
      or name == 'mod4'
      or name == 'alt'
      or name == 'mod1'
    then
      return true
    end
  end
  return false
end

local keypadCodes: { [number]: boolean } = {}
for _, name in { 'kp0', 'kp1', 'kp2', 'kp3', 'kp4', 'kp5', 'kp6', 'kp7', 'kp8', 'kp9', 'kp.' } do
  keypadCodes[fromLovr[name]] = true
end
table.freeze(keypadCodes)

function keys.physicalNativePolicy(
  code: number,
  modifiers: { read [number]: string },
  snapshot: PhysicalModifiers?
): PhysicalNativePolicy
  if keys.commandChord(modifiers) then
    return 'activation'
  end
  if keypadCodes[code] then
    if snapshot == nil then
      return 'unavailable'
    end
    -- XKB's PC KEYPAD type leaves Shift alone at the base level, not the numeric level.
    return if snapshot.numLock and not snapshot.shift then 'text' else 'activation'
  end
  return if printableCodes[code] then 'text' else 'activation'
end

return keys
