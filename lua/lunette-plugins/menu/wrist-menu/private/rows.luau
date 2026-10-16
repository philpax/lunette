-- Turns callback-free menu snapshots into the rows that the wrist menu shows.
local uiHost = require '@lunette-contracts/ui-host'
local menu = require '@lunette-contracts/menu'

local rows = {}

export type Snapshot = { read [number]: menu.Descriptor }

export type Row = {
  -- The row's node key, which encodes the action id so that ids may contain separators.
  read key: string,
  read descriptor: menu.Descriptor,
  read title: string,
  read detail: string?,
  read trailing: string?,
}

function rows.rows(snapshot: Snapshot): { Row }
  local result: { Row } = {}
  for _, descriptor in snapshot do
    result[#result + 1] = {
      key = rows.key(descriptor.id),
      descriptor = descriptor,
      title = descriptor.label,
      detail = if descriptor.group ~= '' then descriptor.group else nil,
      trailing = if descriptor.enabled then nil else 'Unavailable',
    }
  end
  return result
end

-- The key of an action's row.
function rows.key(id: string): string
  return uiHost.keyOf(id)
end

return rows
