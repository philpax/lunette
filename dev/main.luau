-- The development desktop adds a demonstration terminal to the shipped runtime themes.
local desktop = require '@lunette-desktop'
local demoTerminal = require './plugins/demo-terminal'

desktop.run {
  patches = {
    { insert = { id = 'dev/demo-terminal', definition = demoTerminal }, after = 'desktop/adoption' },
  },
}
