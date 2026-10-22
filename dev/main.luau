-- The development desktop adds a demonstration terminal, the UI toolkit's widget gallery, and a performance panel to the
-- shipped desktop.
local desktop = require '@lunette-desktop'
local demoTerminal = require './plugins/demo-terminal'
local uiGallery = require './plugins/ui-gallery'
local perf = require './plugins/perf'

desktop.run {
  patches = {
    { insert = { id = 'dev/demo-terminal', definition = demoTerminal.definition }, after = 'desktop/adoption' },
    { insert = { id = 'dev/ui-gallery', definition = uiGallery.definition }, after = 'dev/demo-terminal' },
    { insert = { id = 'dev/perf', definition = perf.definition }, after = 'dev/ui-gallery' },
  },
}
