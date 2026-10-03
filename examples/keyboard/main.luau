-- The shipped desktop with its keyboard replaced and the wrist button moved.
--
-- Copy this file and split.luau into the directory `lunette --dump-config`
-- wrote, which also holds conf.luau and the .luaurc that `lunette check` and an
-- editor read. docs/guide/writing-plugins.md walks through it.
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    -- The keyboard entry keeps its id and takes another definition. Every
    -- consumer of the keyboard contract, the wrist button included, now gets
    -- the split keyboard.
    { id = 'keyboard', definition = require './split' },
    -- The wrist button's options merge over its defaults.
    desktop.configure(require '@lunette-plugins/desktop/keyboard') { hand = 'right', placement = { distance = 0.45 } },
  },
}
