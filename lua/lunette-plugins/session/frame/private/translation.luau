-- Translates LÖVR key events into evdev codes and modifier names, once, for every key and text handler.
local lunette = require '@lunette'
local keys = require '@lunette-contracts/keys'

local translation = {}

export type LovrModifiers = {
  read shift: boolean,
  read control: boolean,
  read alt: boolean,
  read super: boolean,
  read capsLock: boolean,
  read numLock: boolean,
}

local codes = keys.CODES

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
translation.FROM_LOVR = table.freeze(fromLovr)

type PolledModifier = {
  read keys: { KeyCode },
  read modifier: lunette.ModifierName,
}

-- Right Alt is the level-three modifier, so it is polled apart from left Alt.
local polled: { PolledModifier } = {
  { keys = { 'lctrl', 'rctrl' }, modifier = 'control' },
  { keys = { 'lalt' }, modifier = 'alt' },
  { keys = { 'ralt' }, modifier = 'mod5' },
  { keys = { 'lgui', 'rgui' }, modifier = 'logo' },
  { keys = { 'lshift', 'rshift' }, modifier = 'shift' },
}
table.freeze(polled)

-- The modifiers held now, for a backend whose host events carry no modifier snapshot.
function translation.held(isDown: (KeyCode) -> boolean): { lunette.ModifierName }
  local held: { lunette.ModifierName } = {}
  for _, entry in ipairs(polled) do
    for _, name in ipairs(entry.keys) do
      if isDown(name) then
        held[#held + 1] = entry.modifier
        break
      end
    end
  end
  return held
end

-- LÖVR spells the logo modifier `super`; the snapshot uses the seat's name for it.
function translation.snapshot(value: LovrModifiers): keys.PhysicalModifiers
  return table.freeze {
    shift = value.shift,
    control = value.control,
    alt = value.alt,
    logo = value.super,
    capsLock = value.capsLock,
    numLock = value.numLock,
  }
end

-- The host snapshot is authoritative. It combines both Alt keys, so only the side of Alt is polled.
function translation.fromHost(value: keys.PhysicalModifiers, isDown: (KeyCode) -> boolean): { lunette.ModifierName }
  local result: { lunette.ModifierName } = {}
  local rightAlt = value.alt and isDown 'ralt'
  local leftAlt = value.alt and isDown 'lalt'
  if value.control then
    result[#result + 1] = 'control'
  end
  if value.alt and (not rightAlt or leftAlt) then
    result[#result + 1] = 'alt'
  end
  if rightAlt then
    result[#result + 1] = 'mod5'
  end
  if value.logo then
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

return translation
