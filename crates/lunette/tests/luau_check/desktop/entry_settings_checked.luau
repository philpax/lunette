-- Correct entry-specific and shorthand configuration checks cleanly; each rejected call reports its own line.
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local wristKeyboard = require '@lunette-plugins/desktop/keyboard'
local arrange = require '@lunette-plugins/desktop/arrange'
local persistence = require '@lunette-plugins/arrangement'

local accepted = {
  plugin.configureEntry('custom-keyboard-id', wristKeyboard) { hand = 'right' },
  desktop.configureEntry('custom-arrange-id', arrange) { layout = 'grid' },
  plugin.configureEntry('custom-persistence-id', persistence.factory) { file = 'desktop.state' },
  plugin.configureEntry<<wristKeyboard.Config>>('explicit-config-id', wristKeyboard) { hand = 'left' },
}
local composed = desktop.compose {
  settings = {
    bindings = { reload = { key = 'f5', modifiers = { 'control' } } },
    wristKeyboard = { hand = 'right', placement = { distance = 0.45 } },
    persistence = { file = 'desktop.state' },
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
  },
  workspaces = { workspaces = { { name = 'work', key = '1' }, { name = 'web', key = '2' } } },
}

local rejected = {
  plugin.configureEntry('custom-keyboard-id', wristKeyboard) { hand = 'rigth' }, -- reject.
  desktop.configureEntry('custom-arrange-id', arrange) { layout = 3 }, -- reject.
  plugin.configureEntry('custom-persistence-id', persistence.factory) { file = 3 }, -- reject.
  plugin.configureEntry<<wristKeyboard.Config>>('explicit-config-id', wristKeyboard) { hand = 'rigth' }, -- reject.
  desktop.compose { settings = { wristKeyboard = { hand = 'rigth' } } }, -- reject.
  desktop.compose { settings = { arrange = { layout = 3 } } }, -- reject.
  desktop.compose { settings = { persistence = { file = 3 } } }, -- reject.
  desktop.compose { settings = { bindings = { reload = { key = 'not-a-key' } } } }, -- reject.
  desktop.compose { workspaces = { workspaces = { { name = 'work', key = 'not-a-key' } } } }, -- reject.
}

return { accepted = accepted, composed = composed, rejected = rejected }
