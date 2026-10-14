-- Copies a panel's resolved geometry, controls, and items into inspection registrations without running callbacks.
local inspection = require '@lunette-contracts/inspection'
local ui = require '@lunette-contracts/ui'
local records = require './panel-state'
local input = require '../controls/input'
local panelDraw = require './panel-draw'

local panelInspection = {}

-- Appends the panel, then each control in input order, then each control's items.
function panelInspection.append(
  result: { inspection.Registration },
  state: records.Panel,
  live: (ui.Owner) -> boolean
): ()
  state.refresh()
  local x, y, z, angle, ax, ay, az = state.pose:getPose()
  local controls = input.ordered(state.controls)
  local visible = state.visible and not state.dead
  result[#result + 1] = inspection.registration('panel', 'ui.newPanel', state.owner, state.name, live(state.owner), {
    visible = visible,
    revision = state.revision,
    width = state.width,
    height = state.height,
    logicalWidth = state.logicalWidth,
    logicalHeight = state.logicalHeight,
    x = x,
    y = y,
    z = z,
    angle = angle,
    ax = ax,
    ay = ay,
    az = az,
  })
  for _, record in controls do
    if not record.dead then
      local details: { [string]: string | number | boolean } =
        { panel = state.name, kind = record.kind, label = record.label, enabled = record.enabled }
      local bounds = input.bounds(state, record)
      if bounds then
        details.x, details.y, details.width, details.height = bounds.x, bounds.y, bounds.width, bounds.height
      end
      local source = 'ui.' .. record.kind
      result[#result + 1] =
        inspection.registration('control', source, record.owner, record.id, live(record.owner), details)
      for _, item in panelDraw.clippedItems(state, record) do
        local itemDetails: { [string]: string | number | boolean } = {
          panel = state.name,
          control = record.id,
          label = item.label,
          enabled = item.enabled,
          selected = item.selected,
        }
        local itemBounds = item.bounds
        if itemBounds then
          itemDetails.x, itemDetails.y = itemBounds.x, itemBounds.y
          itemDetails.width, itemDetails.height = itemBounds.width, itemBounds.height
        end
        result[#result + 1] =
          inspection.registration('item', source, record.owner, item.id, live(record.owner), itemDetails)
      end
    end
  end
end

return panelInspection
