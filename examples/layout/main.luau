-- The desktop registers grid and follow layouts, then selects the grid layout.
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    ['desktop/arrange'] = { layout = 'grid' },
  },
  patches = {
    -- Each inserted plugin registers one layout by name and owns its options.
    { insert = { id = 'grid-layout', definition = require('./grid').definition, config = { columns = 3 } } },
    { insert = { id = 'follow-layout', definition = require('./follow').definition } },
  },
}
