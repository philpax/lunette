-- Observes the real development configuration without retaining a runtime across source reloads.
local desktop = require '@lunette-desktop'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local keyboard = require '@lunette-contracts/keyboard'
local composition = require '@lunette-contracts/composition'
local focus = require '@lunette-contracts/focus'

local observer = {}

function observer.load()
  local definition = plugin.define {
    name = 'development-test-observer',
    requires = {
      ui = ui.capability,
      display = display.capability,
      surfaces = surfaces.capability,
      keyboard = keyboard.capability,
      composition = composition.capability,
      focus = focus.capability,
    },
    init = function(context)
      _G.devTestServices = {
        ui = context:require(ui.capability),
        display = context:require(display.capability),
        surfaces = context:require(surfaces.capability),
        keyboard = context:require(keyboard.capability),
        composition = context:require(composition.capability),
        focus = context:require(focus.capability),
        owner = context,
      }
      context:effect(function()
        return function()
          _G.devTestServices = nil
        end
      end)
    end,
  }
  local run = desktop.run
  desktop.run = function(options)
    local observed = table.clone(options or {})
    observed.patches = table.clone(observed.patches or {})
    observed.patches[#observed.patches + 1] = {
      insert = { id = 'development-test-observer', definition = definition },
    }
    run(observed)
  end
  local ok, failure = pcall(function()
    require '../../main'
  end)
  desktop.run = run
  if not ok then
    error(failure, 0)
  end
end

return observer
