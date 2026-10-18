-- Correct patches and settings check cleanly; each rejected one reports its own line.
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local keyboard = require '@lunette-plugins/input/keyboard-display'
local persistence = require '@lunette-plugins/layout/persistence'

local accepted = {
  plugin.configure('custom-keyboard-id', keyboard.definition) { placement = { distance = 0.45 } },
  plugin.configure('custom-persistence-id', persistence.definition) { file = 'desktop.state' },
}
local patches: { plugin.Patch } = {
  { id = 'desktop/backdrop', disabled = true },
  { id = 'desktop/menu', config = { hand = 'left' } },
  { id = 'desktop/keyboard', definition = keyboard.definition, config = { placement = { distance = 0.5 } } },
  { insert = { id = 'custom-keyboard-id', definition = keyboard.definition }, after = 'desktop/keyboard' },
}
local composed = desktop.compose {
  patches = patches,
  settings = {
    laser = { aim = { enabled = false } },
    ['layout/arc'] = { tuning = { radius = 2 } },
    ['desktop/menu'] = { hand = 'right' },
    ['desktop/arrange'] = { layout = 'grid' },
    ['desktop/workspaces'] = { names = { 'work', 'web' } },
  },
}

local wrongPatches: { plugin.Patch } = {
  { id = 'desktop/backdrop', disabled = false }, -- reject.
  { id = 'desktop/backdrop' }, -- reject.
}

local rejected = {
  plugin.configure('custom-keyboard-id', keyboard.definition) { placement = { distance = 'far' } }, -- reject.
  plugin.configure('custom-persistence-id', persistence.definition) { file = 3 }, -- reject.
  desktop.compose { settings = { ['desktop/menu'] = { hand = 'rigth' } } }, -- reject.
  desktop.compose { settings = { ['desktop/arrange'] = { layout = 3 } } }, -- reject.
  desktop.compose { settings = { ['layout/arc'] = { tuning = { radius = 'far' } } } }, -- reject.
}

return { accepted = accepted, composed = composed, rejected = rejected, wrongPatches = wrongPatches }
