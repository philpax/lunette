-- The desktop adds a Dusk theme, starts with it, and leaves out the Arcade theme.
local desktop = require '@lunette-desktop'
local selector = require '@lunette-plugins/desktop/theme'

desktop.run {
  patches = {
    -- The inserted plugin registers Dusk with the theme catalog.
    { insert = { id = 'example/theme/dusk', definition = require './dusk' } },
    -- The selector names a theme from the catalog.
    desktop.configure('desktop/theme', selector) { preset = 'dusk' },
    -- Arcade is an ordinary plugin, so disabling its entry removes its choice.
    { id = 'theme/arcade', disabled = true },
  },
}
