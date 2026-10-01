-- The shipped desktop with its behaviour changed through hooks, bindings, and
-- configuration rather than by replacing plugins.
--
-- Copy this file, upright.lua, and hide-windows.lua into the directory
-- `lunette --dump-config` wrote, which also holds conf.lua and the .luaurc that
-- `lunette check` and an editor read. docs/guide/writing-plugins.md walks
-- through it.
require('@lunette-desktop').run {
  patches = {
    -- Carried panels stay level, whatever the hand does.
    { id = 'interaction', config = { constrain = require './upright' } },
    -- The A button right-clicks, beside the trigger's left click.
    {
      id = 'laser',
      config = {
        buttons = {
          { control = 'trigger', button = 'left' },
          { control = 'a', button = 'right' },
        },
      },
    },
    -- The reload key needs control as well, so F5 alone reaches the client.
    { id = 'desktop/bindings', config = { reload = { key = 'f5', modifiers = { 'control' } } } },
    -- Title bars in another colour.
    { id = 'desktop/decorations', config = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } } },
    { insert = { id = 'hide-windows', definition = require './hide-windows' } },
  },
}
