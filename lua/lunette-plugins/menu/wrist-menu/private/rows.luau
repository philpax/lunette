-- Turns callback-free menu snapshots into the rows that the wrist menu shows: a heading for each group, in
-- alphabetical order, followed by the group's actions in alphabetical order of their labels. Actions without a group
-- come last, under Other.
local uiHost = require '@lunette-contracts/ui-host'
local menu = require '@lunette-contracts/menu'

local rows = {}

export type Snapshot = { read [number]: menu.Descriptor }

export type Row =
  {
    read kind: 'action',
    -- The row's node key, which encodes the action id so that ids may contain separators.
    read key: string,
    read descriptor: menu.Descriptor,
    read title: string,
    read trailing: string?,
  }
  | { read kind: 'group', read key: string, read title: string }

local UNGROUPED = 'Other'

local before: (string, string) -> boolean

function rows.rows(snapshot: Snapshot): { Row }
  local groups: { [string]: { menu.Descriptor } } = {}
  local names: { string } = {}
  for _, descriptor in snapshot do
    local group = descriptor.group
    local members = groups[group]
    if not members then
      members = {}
      groups[group] = members
      table.insert(names, group)
    end
    table.insert(members, descriptor)
  end
  table.sort(names, function(first: string, second: string): boolean
    if (first == '') ~= (second == '') then
      return second == ''
    end
    return before(first, second)
  end)
  local result: { Row } = {}
  for _, name in names do
    local title = if name == '' then UNGROUPED else name
    local heading: Row = { kind = 'group', key = rows.groupKey(name), title = title }
    table.insert(result, heading)
    local members = groups[name]
    table.sort(members, function(first: menu.Descriptor, second: menu.Descriptor): boolean
      if first.label ~= second.label then
        return before(first.label, second.label)
      end
      return first.id < second.id
    end)
    for _, descriptor in members do
      local action: Row = {
        kind = 'action',
        key = rows.key(descriptor.id),
        descriptor = descriptor,
        title = descriptor.label,
        trailing = if descriptor.enabled then nil else 'Unavailable',
      }
      table.insert(result, action)
    end
  end
  return result
end

-- The key of an action's row.
function rows.key(id: string): string
  return uiHost.keyOf(id)
end

-- The key of a group's heading. An encoded action id never begins with %00, because the encoding escapes only
-- printable separators, so a heading cannot share a key with an action.
function rows.groupKey(group: string): string
  return '%00' .. uiHost.keyOf(group)
end

-- Alphabetical order that ignores case and reads runs of digits as numbers, so Workspace 2 comes before Workspace 10.
-- The exact text breaks ties.
before = function(first: string, second: string): boolean
  local a, b = string.lower(first), string.lower(second)
  local i, j = 1, 1
  while i <= #a and j <= #b do
    local digitsA = string.match(a, '^%d+', i)
    local digitsB = string.match(b, '^%d+', j)
    if digitsA and digitsB then
      local numberA, numberB = tonumber(digitsA) :: number, tonumber(digitsB) :: number
      if numberA ~= numberB then
        return numberA < numberB
      end
      i += #digitsA
      j += #digitsB
    else
      local charA, charB = string.sub(a, i, i), string.sub(b, j, j)
      if charA ~= charB then
        return charA < charB
      end
      i += 1
      j += 1
    end
  end
  if (#a - i) ~= (#b - j) then
    return #a - i < #b - j
  end
  return first < second
end

return rows
