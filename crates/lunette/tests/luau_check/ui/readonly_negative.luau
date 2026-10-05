local ui = require '@lunette-contracts/ui'

type RequiredLabel = { read id: string, read bounds: ui.Bounds, read label: string }
type WritableBounds = { x: number, y: number, width: number, height: number }
type WritableItems = { [number]: ui.ItemDescription }

local function misuse(
  options: ui.Options,
  description: ui.Description,
  visual: ui.Visual,
  panel: ui.Panel,
  control: ui.Control
): ()
  local required: RequiredLabel = options -- reject.
  local writableBounds: WritableBounds = options.bounds -- reject.
  local writableItems: WritableItems = visual.items -- reject.
  options.label = 'changed' -- reject.
  options.bounds.x = 1 -- reject.
  description.visible = false -- reject.
  description.generation.kind = 'ui-generation' -- reject.
  description.pose[1] = 0 -- reject.
  description.controls[1] = description.controls[1] -- reject.
  visual.theme.control[1] = 0 -- reject.
  visual.items[1].selected = false -- reject.
  panel.dead = true -- reject.
  local owner: ui.OwnerIdentity = control.owner
  control.owner = owner -- reject.
  owner.kind = 'ui-owner' -- reject.
  description.controls[1].owner = owner -- reject.
  description.controls[1].owner.kind = 'ui-owner' -- reject.
  local wrongOwner: ui.OwnerIdentity = description.generation -- reject.
  local wrongGeneration: ui.Generation = owner -- reject.
  assert(wrongOwner.kind == 'ui-owner' and wrongGeneration.kind == 'ui-generation')
  assert(required.label ~= '' and writableBounds.x >= 0 and #writableItems >= 0)
end

return misuse
