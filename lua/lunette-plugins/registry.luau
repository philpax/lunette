-- Named values belong to the owners that register them. A name is registered once at a time.

local plugin = require '@lunette-plugin'
local inspection = require '@lunette-contracts/inspection'

local registry = {}

export type Entry<T> = {
  read owner: plugin.Owner,
  read name: string,
  read value: T,
  read details: inspection.Details,
}

export type Registry<T> = {
  -- Raises `<label>: <name> is already registered` when the name is taken.
  add: (self: Registry<T>, owner: plugin.Owner, name: string, value: T, details: inspection.Details?) -> plugin.Effect,
  get: (self: Registry<T>, name: string) -> T?,
  -- Lists live registrations in registration order.
  list: (self: Registry<T>) -> { Entry<T> },
  inspect: (self: Registry<T>, kind: inspection.Kind, source: string) -> { inspection.Registration },
}

function registry.new<T>(context: plugin.Context, label: string, onChange: (() -> ())?): Registry<T>
  local entries: { Entry<T> } = {}
  local named: { [string]: Entry<T> } = {}

  local function changed(): ()
    if onChange then
      onChange()
    end
  end

  return {
    add = function(
      _self: Registry<T>,
      owner: plugin.Owner,
      name: string,
      value: T,
      details: inspection.Details?
    ): plugin.Effect
      if named[name] then
        error(label .. ': ' .. name .. ' is already registered', 3)
      end
      local entry: Entry<T> =
        table.freeze { owner = owner, name = name, value = value, details = table.freeze(table.clone(details or {})) }
      local effect = context:acquire(owner, function(): () -> ()
        entries[#entries + 1] = entry
        named[name] = entry
        return function(): ()
          if named[name] ~= entry then
            return
          end
          named[name] = nil
          local index = table.find(entries, entry)
          if index then
            table.remove(entries, index)
          end
          changed()
        end
      end)
      changed()
      return effect
    end,
    get = function(_self: Registry<T>, name: string): T?
      local entry = named[name]
      if entry and context:owns(entry.owner) then
        return entry.value
      end
      return nil
    end,
    list = function(_self: Registry<T>): { Entry<T> }
      local result: { Entry<T> } = {}
      for _, entry in entries do
        if context:owns(entry.owner) then
          result[#result + 1] = entry
        end
      end
      return result
    end,
    inspect = function(_self: Registry<T>, kind: inspection.Kind, source: string): { inspection.Registration }
      local result: { inspection.Registration } = {}
      for _, entry in entries do
        result[#result + 1] =
          inspection.registration(kind, source, entry.owner, entry.name, context:owns(entry.owner), entry.details)
      end
      return result
    end,
  }
end

return registry
