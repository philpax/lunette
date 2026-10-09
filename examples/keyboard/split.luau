-- The keyboard uses evdev key positions, so seat keymaps provide its legends.

local keyboard = require '@lunette-plugins/keyboard'
local drawing = require '@lunette-plugins/keyboard/draw'
local keys = require '@lunette-contracts/keys'

local codes = keys.CODES

local SPLIT = 1.5

local FLASH = 0.15

-- The provider configuration checks each row against the schema input type.
local letters: keyboard.Config = {
  rows = {
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
  },
}

-- The two-row `+` key leaves a spacer in the following row.
local numpad: keyboard.Config = {
  rows = {
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
  },
}

-- Weak keys let pressed-state entries disappear when their row entries are released.
local pressedAt: { [keyboard.Key]: number } = setmetatable({}, { __mode = 'k' })

return {
  definition = keyboard.define {
    name = 'split-keyboard',
    rows = letters.rows,
    layers = { numpad = numpad.rows },
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
  },
}
