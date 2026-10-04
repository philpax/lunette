-- The desktop registers grid and follow layouts, then selects the grid layout.
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    -- `options` selects per-layout settings by layout name.
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
  },
  patches = {
    -- Each inserted plugin registers one layout by name.
    { insert = { id = 'grid-layout', definition = require './grid' } },
    { insert = { id = 'follow-layout', definition = require './follow' } },
  },
}
