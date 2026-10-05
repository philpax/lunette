-- Custom regions retain declared item geometry while sharing pointer and focus delivery.
local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'
local control = require '@lunette-plugins/ui/control'
local geometry = require '@lunette-plugins/ui/geometry'
local validation = require './validation'

local region = {}

function region.new(options: ui.RegionOptions, host: control.Host): control.Widget
  options = validation.region(options)
  local items = if options.items ~= nil then options.items else validation.regionItems {}
  local widget: control.Widget = {
    kind = 'region',
    methods = {
      setItems = function(_self: ui.Region, given: { read [number]: ui.RegionItem }): ()
        if host.live() then
          local replacement = validation.regionItems(given)
          items = replacement
          host.changed()
          host.cancel 'control-removed'
        end
      end,
    },
    receiver = options.receiver,
    wantsKeyboard = options.wantsKeyboard == true,
    pointer = function(event: surface.PointerEvent, _item: string?): ()
      if event.kind == 'press' and event.button == 'left' and event.inside and options.receiver then
        local pointer, button = event.pointer, event.button
        host.focus()
        if not host.interactive() or not host.captured(pointer, button) then
          return
        end
      end
      local onPointer = options.onPointer
      if onPointer then
        host.callback('region ' .. options.id, function(): ()
          onPointer(event)
        end, event.kind == 'cancel' or event.kind == 'leave')
      end
    end,
    items = function(bounds: ui.Bounds, _theme: ui.Theme): { read [number]: ui.ItemDescription }
      local described: { ui.ItemDescription } = {}
      for index = 1, #items do
        local item = items[index]
        described[#described + 1] = table.freeze {
          id = item.id,
          label = item.label or '',
          enabled = true,
          selected = false,
          bounds = geometry.intersect(item.bounds, bounds),
          route = item.route,
        }
      end
      return table.freeze(described)
    end,
    visual = function(state: ui.Visual): ui.Visual
      return state
    end,
  }
  return table.freeze(widget)
end

return region
