-- The shipped desktop with its keyboard replaced and the wrist button moved.
--
-- Copy this file and split.lua into the directory `lunette --dump-config`
-- wrote, which also holds conf.lua and the .luaurc that `lunette check` and an
-- editor read. docs/guide/writing-plugins.md walks through it.
require('@lunette-desktop').run {
  patches = {
    -- The keyboard entry keeps its id and takes another definition. Every
    -- consumer of the keyboard contract, the wrist button included, now gets
    -- the split keyboard.
    { id = 'keyboard', definition = require './split' },
    -- The wrist button's options merge over its defaults.
    { id = 'desktop/keyboard', config = { hand = 'right', placement = { distance = 0.45 } } },
  },
}
