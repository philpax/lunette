-- The desktop adds a Dusk theme, starts with it, and leaves out the Arcade theme.
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    -- The selector names a theme from the catalog.
    ['desktop/theme'] = { preset = 'dusk' },
  },
  patches = {
    -- The inserted plugin registers Dusk with the theme catalog.
    { insert = { id = 'example/theme/dusk', definition = require('./dusk').definition } },
    -- Arcade is an ordinary plugin, so disabling its entry removes its choice.
    { id = 'theme/arcade', disabled = true },
  },
}
