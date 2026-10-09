-- The split keyboard replaces the built-in definition, and the desktop menu opens it at the configured placement.
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    ['desktop/menu'] = { hand = 'right' },
    ['desktop/keyboard'] = { placement = { distance = 0.45 } },
  },
  patches = {
    -- The replacement keeps the `keyboard` id, so existing consumers use the split keyboard.
    { id = 'keyboard', definition = require('./split').definition },
  },
}
