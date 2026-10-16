-- Compares compositions and plans the composition calls that restore a recorded good one. Every function is pure.

local composition = require '@lunette-contracts/composition'

local restore = {}

export type Entry = {
  read id: string,
  read config: unknown,
  read enabled: boolean,
  read protected: boolean,
}

export type Recorded = composition.GoodEntry

-- Disables run first, so that a restored provider does not start beside the entry that replaced it, and enables run
-- last, after every configuration they depend on is in place. A restored entry the record names as disabled is
-- disabled last, because restoring an entry starts it.
export type Operation =
  { read kind: 'disable', read id: string }
  | { read kind: 'configure', read id: string, read config: unknown }
  | { read kind: 'restore', read id: string, read config: unknown }
  | { read kind: 'enable', read id: string }

local function operation(value: Operation): Operation
  return table.freeze(value)
end

-- Structural equality over configuration values: tables compare by their keys and values, everything else by `==`.
function restore.equal(left: unknown, right: unknown): boolean
  if left == right then
    return true
  end
  if type(left) ~= 'table' or type(right) ~= 'table' then
    return false
  end
  local a = left :: { [unknown]: unknown }
  local b = right :: { [unknown]: unknown }
  for key, value in a do
    if not restore.equal(value, b[key]) then
      return false
    end
  end
  for key in b do
    if a[key] == nil then
      return false
    end
  end
  return true
end

-- The parts of a composition that a good record keeps, so two reads can be compared.
function restore.capture(entries: { read [number]: Entry }): { Recorded }
  local captured: { Recorded } = {}
  for _, entry in entries do
    captured[#captured + 1] = table.freeze { id = entry.id, config = entry.config, enabled = entry.enabled }
  end
  return captured
end

function restore.same(left: { read [number]: Recorded }, right: { read [number]: Recorded }): boolean
  if #left ~= #right then
    return false
  end
  for index, entry in left do
    local other = right[index]
    if entry.id ~= other.id or entry.enabled ~= other.enabled or not restore.equal(entry.config, other.config) then
      return false
    end
  end
  return true
end

-- The calls that turn `current` into `good`. Protected entries are left alone, because the composition refuses to
-- change them and they cannot have changed since the record. An entry the record does not name is disabled.
function restore.plan(current: { read [number]: Entry }, good: { read [number]: Recorded }): { Operation }
  local now: { [string]: Entry } = {}
  for _, entry in current do
    now[entry.id] = entry
  end
  local recorded: { [string]: Recorded } = {}
  for _, entry in good do
    recorded[entry.id] = entry
  end

  local disables: { Operation } = {}
  local changes: { Operation } = {}
  local enables: { Operation } = {}
  for _, entry in current do
    local wanted = recorded[entry.id]
    if not entry.protected and entry.enabled and (wanted == nil or not wanted.enabled) then
      disables[#disables + 1] = operation { kind = 'disable', id = entry.id }
    end
  end
  for _, wanted in good do
    local entry = now[wanted.id]
    if entry == nil then
      changes[#changes + 1] = operation { kind = 'restore', id = wanted.id, config = wanted.config }
      if not wanted.enabled then
        enables[#enables + 1] = operation { kind = 'disable', id = wanted.id }
      end
    elseif not entry.protected then
      if not restore.equal(entry.config, wanted.config) then
        changes[#changes + 1] = operation { kind = 'configure', id = wanted.id, config = wanted.config }
      end
      if wanted.enabled and not entry.enabled then
        enables[#enables + 1] = operation { kind = 'enable', id = wanted.id }
      end
    end
  end

  local operations: { Operation } = {}
  for _, group in { disables, changes, enables } do
    for _, operation in group do
      operations[#operations + 1] = operation
    end
  end
  return operations
end

return restore
