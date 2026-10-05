local ui = require '@lunette-contracts/ui'

type NewPanel = (ui.Service, ui.Owner, ui.PanelOptions) -> ui.Panel
type SetBounds = (ui.Control, ui.Bounds) -> ()
type SetValue = (ui.TextField, string) -> ()

local function newPanel(self: ui.Service, owner: ui.Owner, options: ui.PanelOptions): ui.Panel
  return self:newPanel(owner, options)
end

local function setBounds(self: ui.Control, bounds: ui.Bounds): ()
  local owner: ui.OwnerIdentity = self.owner
  assert(owner.kind == 'ui-owner')
  self:setBounds(bounds)
end

local function setValue(self: ui.TextField, value: string): ()
  local owner: ui.OwnerIdentity = self.owner
  assert(owner.kind == 'ui-owner')
  self:setValue(value)
end

local create: NewPanel = newPanel
local move: SetBounds = setBounds
local change: SetValue = setValue

return { create, move, change }
