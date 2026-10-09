-- A button activates only on a primary release inside the original gesture.
local ui = require '@lunette-contracts/ui'
local control = require '@lunette-plugins/ui/control'
local validation = require './validation'
local vocabulary = require '@lunette-contracts/vocabulary'

local button = {}

function button.new(options: ui.ButtonOptions, host: control.Host): control.Widget
  options = validation.button(options)
  local pressed: { [vocabulary.Pointer]: boolean } = {}
  local widget: control.Widget = {
    kind = 'button',
    methods = {},
    wantsKeyboard = false,
    pointer = function(event: vocabulary.PointerEvent, _item: string?): ()
      if event.kind == 'press' then
        if event.button == 'left' and event.inside then
          pressed[event.pointer] = true
        end
        return
      end
      if event.kind == 'cancel' then
        if event.button == 'left' then
          pressed[event.pointer] = nil
        end
        return
      end
      if event.kind == 'release' then
        if event.button == 'left' then
          local activate = pressed[event.pointer] == true and event.inside
          pressed[event.pointer] = nil
          if activate and host.live() then
            host.callback('button ' .. options.id, options.onActivate)
          end
        end
        return
      end
    end,
    items = function(_bounds: ui.Bounds, _theme: ui.Theme): { read [number]: ui.ItemDescription }
      return {}
    end,
    visual = function(state: ui.Visual): ui.Visual
      return state
    end,
  }
  return table.freeze(widget)
end

return button
