-- The repository development configuration starts the desktop with a demonstration terminal.
local desktop = require '@lunette-desktop'
local demoTerminal = require './plugins/demo-terminal'

desktop.run {
  patches = {
    { insert = { id = 'dev/demo-terminal', definition = demoTerminal }, after = 'desktop/adoption' },
  },
}
