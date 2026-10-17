-- Validates plain menu inputs and captures values before an owner acquires a registration.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/menu'

local snapshot = {}

export type Metadata = {
  read id: string,
  read label: string,
  read group: string,
  read enabled: boolean,
  read selected: boolean,
}

type Raw = { [unknown]: unknown }

local ACTION_KEYS: { string } = { 'id', 'label', 'group', 'enabled', 'selected', 'run' }
local STATE_KEYS: { string } = { 'enabled', 'selected' }

local function plain(operation: string, field: string, value: unknown): Raw
  if type(value) ~= 'table' then
    error('menu ' .. operation .. ': ' .. field .. ' is a plain table, not a ' .. type(value), 3)
  end
  return value :: Raw
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
  plugin.rejectUnknownFields('menu register', raw, ACTION_KEYS, 2)
  local id = snapshot.id('register', raw.id)
  local label = raw.label
  if type(label) ~= 'string' or label == '' then
    error('menu register: label is a non-empty string, not ' .. tostring(label), 3)
  end
  local group = raw.group
  if group ~= nil and type(group) ~= 'string' then
    error('menu register: group is a string, not a ' .. type(group), 3)
  end
  local enabled = flag('register', 'enabled', raw.enabled)
  local selected = flag('register', 'selected', raw.selected)
  local run = raw.run
  if type(run) ~= 'function' then
    error('menu register: run is a function, not a ' .. type(run), 3)
  end
  return {
    id = id,
    label = label :: string,
    group = (group :: string?) or '',
    enabled = enabled ~= false,
    selected = selected == true,
  },
    run :: () -> ()
end

function snapshot.state(value: unknown): contract.State
  local raw = plain('update', 'state', value)
  plugin.rejectUnknownFields('menu update', raw, STATE_KEYS, 2)
  return { enabled = flag('update', 'enabled', raw.enabled), selected = flag('update', 'selected', raw.selected) }
end

return snapshot
