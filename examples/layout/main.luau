-- The desktop registers grid and follow layouts, then selects the grid layout.
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    -- Each inserted plugin registers one layout by name.
    { insert = { id = 'grid-layout', definition = require './grid' } },
    { insert = { id = 'follow-layout', definition = require './follow' } },
    -- `options` selects per-layout settings by layout name.
    desktop.configure(require '@lunette-plugins/desktop/arrange') {
      layout = 'grid',
      options = { grid = { columns = 3 } },
    },
  },
}
