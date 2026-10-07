-- Hooks, menu actions, and configuration change the shipped desktop's behaviour.
--
-- Copy the desktop configuration and adjacent Lua files into the directory
-- `lunette --dump-config` wrote, which also holds conf.luau and the .luaurc that
-- `lunette check` and an editor read. docs/guide/desktop-configuration.md describes
-- the settings, and docs/guide/writing-plugins.md describes the inserted plugins.
local desktop = require '@lunette-desktop'
local interaction = require '@lunette-plugins/interaction'
local laser = require '@lunette-plugins/laser'

-- Settings reuse each consumer's exported configuration type.
desktop.run {
  settings = {
    decorations = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
    -- A predicate can match any window property.
    rules = {
      rules = {
        {
          match = {
            where = function(window): boolean
              return type(window.title) == 'string' and window.title:lower():find('picture', 1, true) ~= nil
            end,
          },
          properties = { width = 0.6, priority = 20 },
        },
      },
    },
    persistence = { file = 'example.state' },
  },
  -- Two workspaces, chosen from the session menu.
  workspaces = { workspaces = { { name = 'main' }, { name = 'side' } } },
  patches = {
    -- Carried panels stay level, whatever the hand does.
    desktop.configureEntry('interaction', interaction.definition) { constrain = require './upright' },
    -- The A button right-clicks, beside the trigger's left click.
    desktop.configureEntry('laser', laser.definition) {
      buttons = {
        { control = 'trigger', button = 'left' },
        { control = 'a', button = 'right' },
      },
    },
    { insert = { id = 'hide-windows', definition = require './hide-windows' } },
    { insert = { id = 'save-menu', definition = require './save-menu' } },
    -- Errors are also sent as desktop notifications.
    { insert = { id = 'notify-errors', definition = require './notify-errors' } },
  },
}
