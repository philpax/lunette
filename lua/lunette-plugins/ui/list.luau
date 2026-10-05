-- Lists select immutable stable-id items on a primary release and scroll in logical pixels.
local ui = require '@lunette-contracts/ui'
local control = require './control'
local collection = require './collection'

local list = {}

function list.new(options: ui.ListOptions, host: control.Host): control.Widget
  local state = collection.new('list', options, host)
  local methods: { [string]: unknown } = {
    setItems = function(_self: ui.List, items: { read [number]: ui.Item }): ()
      state.setItems(items)
    end,
    setSelected = function(_self: ui.List, id: string?): ()
      state.setSelected(id)
    end,
    selected = function(_self: ui.List): string?
      return state.selected()
    end,
    scroll = function(_self: ui.List, pixels: number): ()
      state.scroll(pixels)
    end,
  }
  local widget: control.Widget = {
    kind = 'list',
    wantsKeyboard = false,
    methods = table.freeze(methods),
    pointer = state.pointer,
    items = state.items,
    visual = state.visual,
  }
  return table.freeze(widget)
end

return list
