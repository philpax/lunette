-- Correct entry-specific and shorthand configuration checks cleanly; each rejected call reports its own line.
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local wristKeyboard = require '@lunette-plugins/desktop/keyboard'
local menu = require '@lunette-plugins/desktop/menu'
local arrange = require '@lunette-plugins/desktop/arrange'
local persistence = require '@lunette-plugins/arrangement'
local workspaces = require '@lunette-plugins/desktop/workspaces'
local workspaceConfig = require '@lunette-plugins/desktop/workspaces/config'

local accepted = {
  plugin.configureEntry('custom-keyboard-id', wristKeyboard) { placement = { distance = 0.45 } },
  plugin.configureEntry('custom-menu-id', menu) { hand = 'right' },
  desktop.configureEntry('custom-arrange-id', arrange) { layout = 'grid' },
  plugin.configureEntry('custom-persistence-id', persistence.factory) { file = 'desktop.state' },
  plugin.configureEntry<<wristKeyboard.Config>>('explicit-config-id', wristKeyboard) {
    placement = { distance = 0.45 },
  },
}
local composed = desktop.compose {
  settings = {
    menu = { hand = 'right' },
    wristKeyboard = { placement = { distance = 0.45 } },
    persistence = { file = 'desktop.state' },
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
  },
  workspaces = { workspaces = { { name = 'work' }, { name = 'web' } } },
}

local rejected = {
  plugin.configureEntry('custom-keyboard-id', wristKeyboard) { placement = { distance = 'far' } }, -- reject.
  desktop.configureEntry('custom-arrange-id', arrange) { layout = 3 }, -- reject.
  plugin.configureEntry('custom-persistence-id', persistence.factory) { file = 3 }, -- reject.
  plugin.configureEntry<<wristKeyboard.Config>>('explicit-config-id', wristKeyboard) {
    placement = { distance = 'far' }, -- reject.
  },
  desktop.compose { settings = { menu = { hand = 'rigth' } } }, -- reject.
  desktop.compose { settings = { arrange = { layout = 3 } } }, -- reject.
  desktop.compose { settings = { persistence = { file = 3 } } }, -- reject.
}

local settings: desktop.Settings = {}
settings.bindings = {} -- reject.
local board: wristKeyboard.Config = {}
board.hand = 'right' -- reject.
local workspace: workspaces.Config = {}
workspace.modifiers = { 'control' } -- reject.
local named: workspaceConfig.WorkspaceInput = { name = 'main' }
named.key = '1' -- reject.

return { accepted = accepted, composed = composed, rejected = rejected }
