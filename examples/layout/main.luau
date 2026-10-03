-- The shipped desktop with its windows arranged in a grid.
--
-- Copy this file, grid.luau, and follow.luau into the directory
-- `lunette --dump-config` wrote, which also holds conf.luau and the .luaurc that
-- `lunette check` and an editor read. docs/guide/writing-plugins.md walks
-- through it.
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    -- Each layout is a plugin of its own that registers with the layouts
    -- broker; inserting it makes the layout available by name.
    { insert = { id = 'grid-layout', definition = require './grid' } },
    { insert = { id = 'follow-layout', definition = require './follow' } },
    -- The arranging consumer names the layout it uses, and `options` gives each layout its own options by
    -- name. `desktop.configure` lets the checker read them against the consumer's options.
    desktop.configure(require '@lunette-desktop/arrange') { layout = 'grid', options = { grid = { columns = 3 } } },
  },
}
