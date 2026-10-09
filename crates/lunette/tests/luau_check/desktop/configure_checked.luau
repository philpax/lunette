-- A configure patch is checked against its definition's options, with the
-- configuration type inferred from the definition or factory it names.
-- The first block is correct and checks cleanly; each call in the second
-- carries one error, which the test finds by line. A misspelt key is not
-- among them: Luau does not flag an extra key in a table literal, and the
-- entry's own validation reports it when the entry loads.
local desktop = require '@lunette-desktop'
local laser = require '@lunette-plugins/laser'
local keyboard = require '@lunette-plugins/keyboard'
local pacingProvider = require '@lunette-plugins/pacing'
local scaleProvider = require '@lunette-plugins/scale'
local keyboardDisplay = require '@lunette-plugins/desktop/keyboard'
local menu = require '@lunette-plugins/desktop/menu'
local arrange = require '@lunette-plugins/desktop/arrange'
local pacing = require '@lunette-plugins/desktop/pacing'

local accepted = {
  desktop.configure('desktop/keyboard', keyboardDisplay) { placement = { distance = 0.45 } },
  desktop.configure('desktop/menu', menu) {
    hand = 'right',
    size = 0.12,
    offset = vector.pack(-0.03, -0.01, 0.125),
    haptic = { strength = 0.3, duration = 0.05 },
    expanded = {
      width = 0.32,
      height = 0.4,
      logicalWidth = 320,
      logicalHeight = 400,
      rowHeight = 40,
    },
  },
  desktop.configure('laser', laser.definition) { style = { length = 3, color = { 1, 0.4, 0.2, 0.6 } } },
  desktop.configure('desktop/arrange', arrange) { layout = 'grid', options = { grid = { columns = 3 } } },
  desktop.configure('desktop/pacing', pacing) { pauseMonitors = true },
}

local rejected = {
  desktop.configure('desktop/menu', menu) { hand = 'rigth' },
  desktop.configure('desktop/keyboard', keyboardDisplay) { placement = { distance = 'far' } },
  desktop.configure('laser', laser.definition) { style = { length = 'long' } },
  desktop.configure('desktop/arrange', arrange) { layout = 3 },
  desktop.configure('keyboard', keyboard.definition) { rows = 'qwerty' },
  desktop.configure('pacing', pacingProvider.definition) { tuning = { background = 'low' } },
  desktop.configure('scale', scaleProvider.definition) { tuning = { raise = true } },
  desktop.configure('desktop/pacing', pacing) { pauseMonitors = 1 },
}

return { accepted, rejected }
