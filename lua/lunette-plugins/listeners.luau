-- Listener delivery uses a registration snapshot at dispatch start. Each callback requires a live owner.

local plugin = require '@lunette-plugin'
local protected = require '@lunette-plugins/protected'
local inspection = require '@lunette-contracts/inspection'

local listeners = {}

export type Listeners<T> = {
  add: (self: Listeners<T>, owner: plugin.Owner, listener: T, details: inspection.Details?) -> plugin.Effect,
  inspect: (self: Listeners<T>, source: string) -> { inspection.Registration },
  -- Reports callback errors under `label` and continues to the remaining listeners.
  each: (self: Listeners<T>, label: string, call: (T) -> (), wanted: ((T) -> boolean)?) -> (),
  -- Forgets every listener, as at the end of the provider's activation.
  clear: (self: Listeners<T>) -> (),
}

type Entry<T> = {
  owner: plugin.Owner,
  listener: T,
  details: inspection.Details,
  active: boolean,
}

function listeners.new<T>(context: plugin.Context): Listeners<T>
  local entries: { Entry<T> } = {}
  return {
    inspect = function(_self: Listeners<T>, source: string): { inspection.Registration }
      local result: { inspection.Registration } = {}
      for _, entry in ipairs(entries) do
        result[#result + 1] = inspection.registration(
          'listener',
          source,
          entry.owner,
          nil,
          entry.active and context:owns(entry.owner),
          entry.details
        )
      end
      return result
    end,
    add = function(_self: Listeners<T>, owner: plugin.Owner, listener: T, details: inspection.Details?): plugin.Effect
      local entry: Entry<T> =
        { owner = owner, listener = listener, details = table.clone(details or {}), active = true }
      return context:acquire(owner, function(): () -> ()
        entries[#entries + 1] = entry
        return function(): ()
          entry.active = false
          local index = table.find(entries, entry)
          if index then
            table.remove(entries, index)
          end
        end
      end)
    end,
    each = function(_self: Listeners<T>, label: string, call: (T) -> (), wanted: ((T) -> boolean)?): ()
      for _, entry in ipairs(table.clone(entries)) do
        local listener = entry.listener
        if entry.active and context:owns(entry.owner) and (wanted == nil or wanted(listener)) then
          protected.call(label, function(): ()
            call(listener)
          end)
        end
      end
    end,
    clear = function(_self: Listeners<T>): ()
      for _, entry in ipairs(entries) do
        entry.active = false
      end
      table.clear(entries)
    end,
  }
end

return listeners
