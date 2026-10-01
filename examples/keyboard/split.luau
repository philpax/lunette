-- A split keyboard with a numpad layer, a click on every key, and a flash on
-- the key that was pressed.
--
-- It is the built-in keyboard provider with other options: `keyboard.define`
-- makes a definition whose defaults are these, and main.luau puts it in the
-- place of the desktop's `keyboard` entry. Keys are evdev positions, so the
-- legends still come from the seat's keymap.

local keyboard = require '@lunette-plugins/keyboard'
local drawing = require '@lunette-plugins/keyboard/draw'
local keys = require '@lunette-contracts/keys'

local codes = keys.CODES

-- Room between the two halves, in key units.
local SPLIT = 1.5

-- How long a pressed key stays lit, in seconds.
local FLASH = 0.15

-- Rows are annotated, so the checker reads each key against `Key`. An
-- unannotated table is only checked when the keyboard is built.
local letters: { keyboard.KeyRow } = {
  {
    { code = codes.digit1 },
    { code = codes.digit2 },
    { code = codes.digit3 },
    { code = codes.digit4 },
    { code = codes.digit5 },
    { code = codes.digit6, x = SPLIT },
    { code = codes.digit7 },
    { code = codes.digit8 },
    { code = codes.digit9 },
    { code = codes.digit0 },
    { code = codes.backspace, label = 'bksp', width = 1.5 },
  },
  {
    { code = codes.q },
    { code = codes.w },
    { code = codes.e },
    { code = codes.r },
    { code = codes.t },
    { code = codes.y, x = SPLIT },
    { code = codes.u },
    { code = codes.i },
    { code = codes.o },
    { code = codes.p },
  },
  {
    { code = codes.a },
    { code = codes.s },
    { code = codes.d },
    { code = codes.f },
    { code = codes.g },
    { code = codes.h, x = SPLIT },
    { code = codes.j },
    { code = codes.k },
    { code = codes.l },
    { code = codes.enter, label = 'enter', width = 1.5 },
  },
  {
    { code = codes.leftShift, label = 'shift' },
    { code = codes.z },
    { code = codes.x },
    { code = codes.c },
    { code = codes.v },
    { code = codes.b, x = SPLIT },
    { code = codes.n },
    { code = codes.m },
    { code = codes.comma },
    { code = codes.dot },
  },
  {
    { action = { kind = 'layer', layer = 'numpad' }, label = '123' },
    { code = codes.leftCtrl, label = 'ctrl' },
    { code = codes.space, label = 'space', width = 3 },
    { code = codes.space, label = 'space', width = 3, x = SPLIT },
    { action = { kind = 'chord', code = codes.t, modifiers = { 'control', 'alt' } }, label = 'term' },
    { action = { kind = 'hide' } },
  },
}

-- A numpad. The `+` key is two rows tall, so the row below leaves a spacer
-- where it reaches.
local numpad: { keyboard.KeyRow } = {
  {
    { code = codes.digit7 },
    { code = codes.digit8 },
    { code = codes.digit9 },
    { code = codes.minus },
  },
  {
    { code = codes.digit4 },
    { code = codes.digit5 },
    { code = codes.digit6 },
    { action = { kind = 'text', text = '+' }, height = 2 },
  },
  {
    { code = codes.digit1 },
    { code = codes.digit2 },
    { code = codes.digit3 },
    { width = 1 },
  },
  {
    { code = codes.digit0, width = 2 },
    { code = codes.dot },
    { code = codes.enter, label = 'ent' },
  },
  {
    { action = { kind = 'layer', layer = 'base' }, label = 'abc', width = 4 },
  },
}

-- When each key was last pressed, by the row entry it was made from. The
-- entry is the same table for as long as the keyboard shows the same rows, so
-- it identifies a key from one frame to the next.
local pressedAt: { [keyboard.Key]: number } = setmetatable({}, { __mode = 'k' })

return keyboard.define {
  name = 'split-keyboard',
  rows = letters,
  layers = { numpad = numpad },
  style = { keyUnit = 0.03 },
  onKey = function(board, key, pointer, base)
    pointer:vibrate { strength = 0.2, duration = 0.01 }
    pressedAt[key.source] = lovr.timer.getTime()
    base(board, key, pointer)
  end,
  drawKey = function(pass, key, state, base)
    local pressed = pressedAt[key.source]
    if pressed and lovr.timer.getTime() - pressed < FLASH then
      local style = state.style
      pass:setColor(1, 0.8, 0.3, 1)
      pass:plane(lovr.math.mat4(state.pose):scale(key.width - style.gap, key.height - style.gap, 1), 'fill', 1, 1)
      drawing.legend(pass, key, state)
      return
    end
    base(pass, key, state)
  end,
}
