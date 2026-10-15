-- Turns callback-free menu snapshots into UI rows.
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'

local rows = {}

export type Snapshot = { read [number]: menu.Descriptor }

function rows.items(snapshot: Snapshot): { ui.Item }
  local items: { ui.Item } = {}
  for _, descriptor in snapshot do
    local label = descriptor.label
    if descriptor.group ~= '' then
      label = descriptor.group .. ': ' .. label
    end
    if descriptor.selected then
      label ..= ' [selected]'
    end
    if not descriptor.enabled then
      label ..= ' [disabled]'
    end
    items[#items + 1] = { id = descriptor.id, label = label, enabled = descriptor.enabled }
  end
  return items
end

function rows.find(snapshot: Snapshot, id: string): menu.Descriptor?
  for _, descriptor in snapshot do
    if descriptor.id == id then
      return descriptor
    end
  end
  return nil
end

return rows
