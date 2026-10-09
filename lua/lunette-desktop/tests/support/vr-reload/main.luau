-- Exposes live public services to the controller fixture across production source reloads.
local desktop = require '@lunette-desktop'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local ui = require '@lunette-contracts/ui'

local observer = adapter.define {
  name = 'vr-reload-observer',
  requires = { ui.capability },
  init = function(context)
    _G.vrReloadControls = { ui = context:require(ui.capability) }
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
