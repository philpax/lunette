-- The split keyboard replaces the built-in definition while the desktop wrist button uses new placement options.
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    -- The replacement keeps the `keyboard` id, so existing consumers use the split keyboard.
    { id = 'keyboard', definition = require './split' },
    desktop.configure(require '@lunette-plugins/desktop/keyboard') { hand = 'right', placement = { distance = 0.45 } },
  },
}
