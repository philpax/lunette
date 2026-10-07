-- Validates plain menu inputs and captures values before an owner acquires a registration.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/menu'

local snapshot = {}

export type Metadata = {
  read id: string,
  read label: string,
  read group: string,
  read order: number,
  read enabled: boolean,
  read selected: boolean,
}

type Raw = { [unknown]: unknown }

local ACTION_KEYS: { [string]: boolean } = {
  id = true,
  label = true,
  group = true,
  order = true,
  enabled = true,
  selected = true,
  run = true,
}
local STATE_KEYS: { [string]: boolean } = { enabled = true, selected = true }

local function plain(operation: string, field: string, value: unknown): Raw
  if type(value) ~= 'table' then
    error('menu ' .. operation .. ': ' .. field .. ' is a plain table, not a ' .. type(value), 3)
  end
  local raw = value :: Raw
  if getmetatable(raw) ~= nil then
    error('menu ' .. operation .. ': ' .. field .. ' is a plain table without a metatable', 3)
  end
  return raw
end

function snapshot.id(operation: string, value: unknown): string
  if type(value) ~= 'string' or value == '' then
    error('menu ' .. operation .. ': id is a non-empty string, not ' .. tostring(value), 3)
  end
  return value :: string
end

local function flag(operation: string, field: string, value: unknown): boolean?
  if value ~= nil and type(value) ~= 'boolean' then
    error('menu ' .. operation .. ': ' .. field .. ' is a boolean, not a ' .. type(value), 3)
  end
  return value :: boolean?
end

function snapshot.action(value: unknown): (Metadata, () -> ())
  local raw = plain('register', 'action', value)
  plugin.rejectUnknownFields(
    'menu register',
    raw,
    ACTION_KEYS,
    'id, label, group, order, enabled, selected, and run',
    2
  )
  local id = snapshot.id('register', raw.id)
  local label = raw.label
  if type(label) ~= 'string' or label == '' then
    error('menu register: label is a non-empty string, not ' .. tostring(label), 3)
  end
  local group = raw.group
  if group ~= nil and type(group) ~= 'string' then
    error('menu register: group is a string, not a ' .. type(group), 3)
  end
  local order = raw.order
  if order ~= nil and (type(order) ~= 'number' or order ~= order or math.abs(order :: number) == math.huge) then
    error('menu register: order is a finite number, not ' .. tostring(order), 3)
  end
  local enabled = flag('register', 'enabled', raw.enabled)
  local selected = flag('register', 'selected', raw.selected)
  local run = raw.run
  if type(run) ~= 'function' then
    error('menu register: run is a function, not a ' .. type(run), 3)
  end
  return table.freeze {
    id = id,
    label = label :: string,
    group = (group :: string?) or '',
    order = (order :: number?) or 0,
    enabled = enabled ~= false,
    selected = selected == true,
  },
    run :: () -> ()
end

function snapshot.state(value: unknown): contract.State
  local raw = plain('update', 'state', value)
  plugin.rejectUnknownFields('menu update', raw, STATE_KEYS, 'enabled and selected', 2)
  local enabled = flag('update', 'enabled', raw.enabled)
  local selected = flag('update', 'selected', raw.selected)
  return table.freeze { enabled = enabled, selected = selected }
end

return snapshot
