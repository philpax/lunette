-- Correct patches and settings check cleanly; each rejected one reports its own line.
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local keyboard = require '@lunette-plugins/desktop/keyboard'
local menu = require '@lunette-plugins/desktop/menu'
local arrange = require '@lunette-plugins/desktop/arrange'
local persistence = require '@lunette-plugins/arrangement'

local accepted = {
  desktop.configure('desktop/menu', menu) { hand = 'right' },
  desktop.configure('desktop/arrange', arrange) { layout = 'grid', options = { grid = { columns = 3 } } },
  plugin.configure('custom-keyboard-id', keyboard) { placement = { distance = 0.45 } },
  plugin.configure('custom-persistence-id', persistence.factory) { file = 'desktop.state' },
}
local composed = desktop.compose {
  settings = {
    menu = { hand = 'right' },
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
  },
}

local rejected = {
  desktop.configure('desktop/menu', menu) { hand = 'rigth' }, -- reject.
  desktop.configure('desktop/arrange', arrange) { layout = 3 }, -- reject.
  plugin.configure('custom-keyboard-id', keyboard) { placement = { distance = 'far' } }, -- reject.
  plugin.configure('custom-persistence-id', persistence.factory) { file = 3 }, -- reject.
  desktop.compose { settings = { menu = { hand = 'rigth' } } }, -- reject.
  desktop.compose { settings = { arrange = { layout = 3 } } }, -- reject.
}

return { accepted = accepted, composed = composed, rejected = rejected }
