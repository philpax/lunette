-- The shipped desktop with its behaviour changed through hooks, bindings, and
-- configuration rather than by replacing plugins.
--
-- Copy this file and the other Lua files beside it into the directory
-- `lunette --dump-config` wrote, which also holds conf.luau and the .luaurc that
-- `lunette check` and an editor read. docs/guide/writing-plugins.md walks
-- through it.
local desktop = require '@lunette-desktop'
local interaction = require '@lunette-plugins/interaction'
local laser = require '@lunette-plugins/laser'

-- Each `desktop.configure` patch is checked against its definition's options.
-- It names the entry by the definition's name.
desktop.run {
  patches = {
    -- Carried panels stay level, whatever the hand does.
    desktop.configure(interaction.definition) { constrain = require './upright' },
    -- The A button right-clicks, beside the trigger's left click.
    desktop.configure(laser.definition) {
      buttons = {
        { control = 'trigger', button = 'left' },
        { control = 'a', button = 'right' },
      },
    },
    -- The reload key needs control as well, so F5 alone reaches the client.
    desktop.configure(require '@lunette-desktop/bindings') { reload = { key = 'f5', modifiers = { 'control' } } },
    -- Title bars in another colour.
    desktop.configure(require '@lunette-desktop/decorations') { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
    -- Small windows whose title says they are a picture in picture float
    -- above the rest, by a predicate over the whole window.
    desktop.configure(require '@lunette-desktop/rules') {
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
    -- The arrangement goes to a file of its own.
    desktop.configure(require '@lunette-desktop/persistence') { file = 'example.state' },
    { insert = { id = 'hide-windows', definition = require './hide-windows' } },
    { insert = { id = 'save-key', definition = require './save-key' } },
    -- Errors are also sent as desktop notifications.
    { insert = { id = 'notify-errors', definition = require './notify-errors' } },
    -- Two workspaces, switched with control, alt, and a number.
    {
      insert = {
        id = 'desktop/workspaces',
        definition = require '@lunette-desktop/workspaces',
        config = {
          workspaces = { { name = 'main', key = '1' }, { name = 'side', key = '2' } },
          modifiers = { 'control', 'alt' },
        },
      },
    },
  },
}
