-- Exposes live public services and the UI panels to the controller fixture across production source reloads.
local desktop = require '@lunette-desktop'
local adapter = require '@lunette-plugin/adapter'
local uiHost = require '@lunette-contracts/ui-host'
local uiPanels = require '@testing/ui-panels'

local panels = uiPanels.new()

local observer = adapter.define {
  name = 'vr-reload-observer',
  requires = { uiHost.capability },
  init = function(context: adapter.Context)
    _G.vrReloadControls = { host = context:require(uiHost.capability), panels = panels }
    context:effect(function(): () -> ()
      return function()
        _G.vrReloadControls = nil
      end
    end)
  end,
}

desktop.run {
  patches = {
    { id = 'ui-host', definition = panels.definition },
    { insert = { id = 'vr-reload-observer', definition = observer } },
  },
}
