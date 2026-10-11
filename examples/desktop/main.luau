-- Hooks, menu actions, and configuration change the shipped desktop's behaviour. Copy the desktop configuration and adjacent Lua files into the directory `lunette --dump-config` wrote, which also holds conf.luau and the .luaurc that `lunette check` and an editor read. The settings are described in docs/guide/desktop-configuration.md, and the inserted plugins in docs/guide/writing-plugins.md.
local desktop = require '@lunette-desktop'
type Window = typeof(require('@lunette').windows()[1])

-- Settings are keyed by entry id and typed by each entry's configuration.
desktop.run {
  settings = {
    -- Carried panels stay level, whatever the hand does.
    interaction = { constrain = require './upright' },
    -- The A button right-clicks, beside the trigger's left click.
    laser = {
      buttons = {
        { control = 'trigger', button = 'left' },
        { control = 'a', button = 'right' },
      },
    },
    ['desktop/decorations'] = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
    -- A predicate can match any window property.
    ['desktop/rules'] = {
      rules = {
        {
          match = {
            where = function(window: Window): boolean
              return type(window.title) == 'string' and window.title:lower():find('picture', 1, true) ~= nil
            end,
          },
          properties = { width = 0.6, priority = 20 },
        },
      },
    },
    ['desktop/persistence'] = { file = 'example.state' },
    -- Two workspaces, chosen from the session menu.
    ['desktop/workspaces'] = { names = { 'main', 'side' } },
  },
  patches = {
    { insert = { id = 'hide-windows', definition = require('./hide-windows').definition } },
    { insert = { id = 'save-menu', definition = require('./save-menu').definition } },
    -- Errors are also sent as desktop notifications.
    { insert = { id = 'notify-errors', definition = require('./notify-errors').definition } },
  },
}
