-- The split keyboard replaces the built-in definition while the desktop wrist button uses new placement options.
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    wristKeyboard = { hand = 'right', placement = { distance = 0.45 } },
  },
  patches = {
    -- The replacement keeps the `keyboard` id, so existing consumers use the split keyboard.
    { id = 'keyboard', definition = require './split' },
  },
}
