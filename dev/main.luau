-- The development desktop adds a demonstration terminal and the UI toolkit's widget gallery to the shipped desktop.
-- The UI host and standard kinds are inserted here until the shipped desktop composes them.
local desktop = require '@lunette-desktop'
local demoTerminal = require './plugins/demo-terminal'
local uiGallery = require './plugins/ui-gallery'
local uiHost = require '@lunette-plugins/ui/host'
local uiStandard = require '@lunette-plugins/ui/standard'

desktop.run {
  patches = {
    { insert = { id = 'dev/demo-terminal', definition = demoTerminal.definition }, after = 'desktop/adoption' },
    { insert = { id = 'ui-host', definition = uiHost.definition }, after = 'dev/demo-terminal' },
    { insert = { id = 'ui-standard', definition = uiStandard.definition }, after = 'ui-host' },
    { insert = { id = 'dev/ui-gallery', definition = uiGallery.definition }, after = 'ui-standard' },
  },
}
