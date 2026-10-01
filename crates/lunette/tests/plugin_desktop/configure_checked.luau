-- Each typed patch is checked against its entry's options. Every call below
-- carries one error, which the test finds by line. A misspelt key is not
-- among them: Luau does not flag an extra key in a table literal, and the
-- entry's own validation reports it when the entry loads.
local desktop = require '@lunette-desktop'

return {
  desktop.configure['desktop/keyboard'] { hand = 'rigth' },
  desktop.configure.laser { style = { length = 'long' } },
  desktop.configure['desktop/arrange'] { layout = 3 },
  desktop.configure.keyboard { rows = 'qwerty' },
}
