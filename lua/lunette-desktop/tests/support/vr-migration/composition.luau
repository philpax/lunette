-- Builds the real desktop and example form with test-owned lifecycle observations.
local desktop = require '@lunette-desktop'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local focus = require '@lunette-contracts/focus'
local display = require '@lunette-contracts/keyboard-display'
local keyboard = require '@lunette-contracts/keyboard'
local surfaces = require '@lunette-contracts/surfaces'
local panels = require '@lunette-contracts/panels'
local frame = require '@lunette-contracts/frame'
local theme = require '@lunette-contracts/theme'
local composition = {}

function composition.options(observed, ledger, form)
  local observer = plugin.define {
    name = 'vr-migration-observer',
    requires = {
      ui = ui.capability,
      menu = menu.capability,
      focus = focus.capability,
      display = display.capability,
      keyboard = keyboard.capability,
      surfaces = surfaces.capability,
      panels = panels.capability,
      theme = theme.capability,
    },
    init = function(context)
      for name, capability in
        {
          ui = ui.capability,
          menu = menu.capability,
          focus = focus.capability,
          display = display.capability,
          keyboard = keyboard.capability,
          surfaces = surfaces.capability,
          panels = panels.capability,
          theme = theme.capability,
        }
      do
        observed[name] = context:require(capability)
      end
      observed.owner = context
    end,
  }
  local probe = plugin.define {
    name = 'vr-migration-probe',
    requires = { ui = ui.capability, menu = menu.capability, frame = frame.capability },
    init = function(context)
      ledger.activations += 1
      local activation = ledger.activations
      local ownerEnded = false
      local widgets = context:require(ui.capability)
      local panel = widgets:newPanel(context, {
        name = 'vr-migration-probe',
        pose = lovr.math.newMat4():translate(-1.2, 1.1, -1.4),
        width = 0.5,
        height = 0.3,
        logicalWidth = 400,
        logicalHeight = 240,
      })
      local button = panel:button(context, {
        id = 'action',
        bounds = { x = 16, y = 16, width = 160, height = 48 },
        onActivate = function()
          ledger.actions += 1
        end,
      })
      local region = panel:region(context, {
        id = 'capture',
        bounds = { x = 16, y = 88, width = 368, height = 128 },
        onPointer = function(event)
          local record = table.clone(event)
          record.ownerActive = context:active()
          record.ownerEnded = ownerEnded
          record.activation = activation
          ledger.events[#ledger.events + 1] = record
          if event.kind == 'press' then
            ledger.pointer = event.pointer
          elseif event.kind == 'release' then
            ledger.releases += 1
          elseif event.kind == 'cancel' then
            ledger.cancels += 1
          end
        end,
      })
      observed.probe = { panel = panel, button = button, region = region }
      context:require(frame.capability):onDraw(context, {
        phase = 'overlay',
        run = function(pass)
          panel:draw(pass)
        end,
      })
      context:effect(function()
        return function()
          ownerEnded = true
          ledger.ended += 1
        end
      end)
    end,
  }
  local patches = {
    {
      id = 'desktop/theme',
      config = {
        overrides = { typography = { font = { kind = 'file', file = 'fixture-theme.ttf', size = 28, spread = 5 } } },
      },
    },
    { insert = { id = 'example/ui/form', definition = form } },
    { insert = { id = 'vr-migration-observer', definition = observer } },
    { insert = { id = 'vr-migration-probe', definition = probe } },
  }
  return { patches = patches }
end

return composition
