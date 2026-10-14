-- Default ANSI key positions use evdev codes; legends come from the seat keymap unless labeled.
local keyboard = require '@lunette-contracts/keyboard'
local keys = require '@lunette-contracts/keys'

local codes = keys.CODES

local rows: { keyboard.KeyRow } = {
  {
    { code = codes.grave },
    { code = codes.digit1 },
    { code = codes.digit2 },
    { code = codes.digit3 },
    { code = codes.digit4 },
    { code = codes.digit5 },
    { code = codes.digit6 },
    { code = codes.digit7 },
    { code = codes.digit8 },
    { code = codes.digit9 },
    { code = codes.digit0 },
    { code = codes.minus },
    { code = codes.equal },
    { code = codes.backspace, label = 'bksp', width = 2 },
  },
  {
    { code = codes.tab, label = 'tab', width = 1.5 },
    { code = codes.q },
    { code = codes.w },
    { code = codes.e },
    { code = codes.r },
    { code = codes.t },
    { code = codes.y },
    { code = codes.u },
    { code = codes.i },
    { code = codes.o },
    { code = codes.p },
    { code = codes.leftBrace },
    { code = codes.rightBrace },
    { code = codes.backslash, width = 1.5 },
  },
  {
    { code = codes.capsLock, label = 'caps', width = 1.75 },
    { code = codes.a },
    { code = codes.s },
    { code = codes.d },
    { code = codes.f },
    { code = codes.g },
    { code = codes.h },
    { code = codes.j },
    { code = codes.k },
    { code = codes.l },
    { code = codes.semicolon },
    { code = codes.apostrophe },
    { code = codes.enter, label = 'enter', width = 2.25 },
  },
  {
    { code = codes.leftShift, label = 'shift', width = 2.25 },
    { code = codes.z },
    { code = codes.x },
    { code = codes.c },
    { code = codes.v },
    { code = codes.b },
    { code = codes.n },
    { code = codes.m },
    { code = codes.comma },
    { code = codes.dot },
    { code = codes.slash },
    { code = codes.rightShift, label = 'shift', width = 2.75 },
  },
  {
    { code = codes.leftCtrl, label = 'ctrl', width = 1.25 },
    { code = codes.leftMeta, label = 'logo', width = 1.25 },
    { code = codes.leftAlt, label = 'alt', width = 1.25 },
    { code = codes.space, label = 'space', width = 6.25 },
    { code = codes.rightAlt, label = 'altgr', width = 1.25 },
    { code = codes.rightCtrl, label = 'ctrl', width = 1.25 },
  },
}

return rows
