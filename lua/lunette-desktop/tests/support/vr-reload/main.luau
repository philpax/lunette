-- Exposes live public services to the controller fixture across production source reloads.
local desktop = require '@lunette-desktop'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local display = require '@lunette-contracts/keyboard-display'
local composition = require '@lunette-contracts/composition'

local observer = plugin.define {
  name = 'vr-reload-observer',
  requires = { ui = ui.capability, display = display.capability, composition = composition.capability },
  init = function(context)
    _G.vrReloadControls = {
      ui = context:require(ui.capability),
      display = context:require(display.capability),
      composition = context:require(composition.capability),
    }
    context:effect(function()
      return function()
        _G.vrReloadControls = nil
      end
    end)
  end,
}

desktop.run {
  patches = { { insert = { id = 'vr-reload-observer', definition = observer } } },
}
