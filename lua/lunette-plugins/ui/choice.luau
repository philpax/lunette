-- Choices expose a primary-release header and scrollable options inside their declared bounds.
local ui = require '@lunette-contracts/ui'
local control = require './control'
local collection = require './collection'

local choice = {}

function choice.new(options: ui.ChoiceOptions, host: control.Host): control.Widget
  if type(options.onChange) ~= 'function' then
    error('ui choice: onChange is a function', 2)
  end
  local state = collection.new('choice', options, host)
  local methods: { [string]: unknown } = {
    setItems = function(_self: ui.Choice, items: { read [number]: ui.Item }): ()
      state.setItems(items)
    end,
    setSelected = function(_self: ui.Choice, id: string?): ()
      state.setSelected(id)
    end,
    selected = function(_self: ui.Choice): string?
      return state.selected()
    end,
    setOpen = function(_self: ui.Choice, opened: boolean): ()
      state.setOpen(opened)
    end,
    scroll = function(_self: ui.Choice, pixels: number): ()
      state.scroll(pixels)
    end,
  }
  local widget: control.Widget = {
    kind = 'choice',
    wantsKeyboard = false,
    methods = table.freeze(methods),
    pointer = state.pointer,
    items = state.items,
    visual = state.visual,
  }
  return table.freeze(widget)
end

return choice
