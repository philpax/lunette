-- The development desktop adds a demonstration terminal and the UI toolkit's widget gallery to the shipped desktop.
local desktop = require '@lunette-desktop'
local demoTerminal = require './plugins/demo-terminal'
local uiGallery = require './plugins/ui-gallery'

desktop.run {
  patches = {
    { insert = { id = 'dev/demo-terminal', definition = demoTerminal.definition }, after = 'desktop/adoption' },
    { insert = { id = 'dev/ui-gallery', definition = uiGallery.definition }, after = 'dev/demo-terminal' },
  },
}
