-- Owner-scoped listeners for a broker provider. A listener is an effect of its owner, called only while
-- its owner is live, and one added or removed during a call is neither heard nor skipped late: the
-- listeners are chosen before any is called.

local plugin = require '@lunette-plugin'
local protected = require '@lunette-plugins/protected'

local listeners = {}

export type Listeners<T> = {
  -- Adds a listener as an effect of `owner`, answering that effect.
  add: (self: Listeners<T>, owner: plugin.Owner, listener: T) -> plugin.Effect,
  -- Calls `call` with each live listener `wanted` accepts, reporting a raise under `label`.
  each: (self: Listeners<T>, label: string, call: (T) -> (), wanted: ((T) -> boolean)?) -> (),
  -- Forgets every listener, as at the end of the provider's activation.
  clear: (self: Listeners<T>) -> (),
}

type Entry<T> = {
  owner: plugin.Owner,
  listener: T,
  active: boolean,
}

function listeners.new<T>(context: plugin.Context): Listeners<T>
  local entries: { Entry<T> } = {}
  return {
    add = function(_self: Listeners<T>, owner: plugin.Owner, listener: T): plugin.Effect
      local entry: Entry<T> = { owner = owner, listener = listener, active = true }
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
