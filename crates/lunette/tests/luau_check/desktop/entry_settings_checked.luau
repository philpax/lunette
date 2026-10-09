-- Correct entry-specific and shorthand configuration checks cleanly; each rejected call reports its own line.
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local keyboard = require '@lunette-plugins/desktop/keyboard'
local menu = require '@lunette-plugins/desktop/menu'
local arrange = require '@lunette-plugins/desktop/arrange'
local persistence = require '@lunette-plugins/arrangement'

local accepted = {
  plugin.configure('custom-keyboard-id', keyboard) { placement = { distance = 0.45 } },
  plugin.configure('custom-menu-id', menu) { hand = 'right' },
  desktop.configure('custom-arrange-id', arrange) { layout = 'grid' },
  plugin.configure('custom-persistence-id', persistence.factory) { file = 'desktop.state' },
  plugin.configure<<keyboard.Config>>('explicit-config-id', keyboard) {
    placement = { distance = 0.45 },
  },
}
local composed = desktop.compose {
  settings = {
    menu = { hand = 'right' },
    keyboardDisplay = { placement = { distance = 0.45 } },
    persistence = { file = 'desktop.state' },
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
    workspaces = { workspaces = { { name = 'work' }, { name = 'web' } } },
  },
}

local rejected = {
  plugin.configure('custom-keyboard-id', keyboard) { placement = { distance = 'far' } }, -- reject.
  desktop.configure('custom-arrange-id', arrange) { layout = 3 }, -- reject.
  plugin.configure('custom-persistence-id', persistence.factory) { file = 3 }, -- reject.
  plugin.configure<<keyboard.Config>>('explicit-config-id', keyboard) {
    placement = { distance = 'far' }, -- reject.
  },
  desktop.compose { settings = { menu = { hand = 'rigth' } } }, -- reject.
  desktop.compose { settings = { arrange = { layout = 3 } } }, -- reject.
  desktop.compose { settings = { persistence = { file = 3 } } }, -- reject.
}

return { accepted = accepted, composed = composed, rejected = rejected }
