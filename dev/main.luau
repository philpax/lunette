-- The development desktop uses the rounded keyboard example and a demonstration terminal.
local desktop = require '@lunette-desktop'
local demoTerminal = require './plugins/demo-terminal'
local roundedKeyboard = require './examples/keyboard/rounded'

desktop.run {
  patches = {
    { id = 'keyboard', definition = roundedKeyboard },
    { insert = { id = 'dev/demo-terminal', definition = demoTerminal }, after = 'desktop/adoption' },
  },
}
