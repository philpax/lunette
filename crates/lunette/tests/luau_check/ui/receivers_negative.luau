local ui = require '@lunette-contracts/ui'

type NarrowService = ui.Service & { read privateState: number }
type NewPanel = (ui.Service, ui.Owner, ui.PanelOptions) -> ui.Panel
type SetBounds = (ui.Control, ui.Bounds) -> ()
type SetValue = (ui.TextField, string) -> ()

local narrow = function(self: NarrowService, owner: ui.Owner, options: ui.PanelOptions): ui.Panel
  assert(self.privateState >= 0)
  return self:newPanel(owner, options)
end
local wrongSelf: NewPanel = narrow -- reject.
local wrongControl: SetBounds = function(_self: ui.Panel, _bounds: ui.Bounds): () end -- reject.
local wrongField: SetValue = function(_self: ui.Choice, _value: string): () end -- reject.

local function misuse(service: ui.Service, panel: ui.Panel, field: ui.TextField, owner: ui.Owner, pass: Pass): ()
  local options: ui.PanelOptions =
    { name = 'wrong-self', width = 1, height = 1, logicalWidth = 100, logicalHeight = 100 }
  service.newPanel(panel, owner, options) -- reject.
  panel.draw(service, pass) -- reject.
  field.setValue(panel, 'value') -- reject.
end

return { wrongSelf, wrongControl, wrongField, misuse }
