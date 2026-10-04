-- The most recent live owner override decides the value. Ending an override reveals the next live override.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local overrides = {}

type Owner = owner.Owner

type Entry<T> = { owner: Owner, value: T, effect: plugin.Effect? }

export type Stack<T> = {
  read set: (Stack<T>, Owner, T) -> boolean,
  read value: (Stack<T>) -> T,
  -- Clears overrides and returns their effects for disposal after caller state is consistent.
  read clear: (Stack<T>) -> { plugin.Effect },
}

-- Owner effects remove overrides. `changed` runs when disposal changes the decided value.
function overrides.new<T>(context: plugin.Context, fallback: T, changed: () -> ()): Stack<T>
  local entries: { Entry<T> } = {}
  local function decided(): T
    local top = entries[#entries]
    if top then
      return top.value
    end
    return fallback
  end
  local stack: Stack<T> = {
    set = function(_self: Stack<T>, caller: Owner, value: T): boolean
      local before = decided()
      for index, entry in ipairs(entries) do
        if entry.owner == caller then
          table.remove(entries, index)
          entry.value = value
          entries[#entries + 1] = entry
          return decided() ~= before
        end
      end
      local entry: Entry<T> = { owner = caller, value = value, effect = nil }
      entry.effect = context:acquire(caller, function(): () -> ()
        entries[#entries + 1] = entry
        return function(): ()
          local index = table.find(entries, entry)
          if index then
            local previous = decided()
            table.remove(entries, index)
            if decided() ~= previous then
              changed()
            end
          end
        end
      end)
      return decided() ~= before
    end,
    value = function(_self: Stack<T>): T
      return decided()
    end,
    clear = function(_self: Stack<T>): { plugin.Effect }
      local ended: { plugin.Effect } = {}
      for _, entry in ipairs(entries) do
        local effect = entry.effect
        if effect then
          ended[#ended + 1] = effect
        end
      end
      table.clear(entries)
      return ended
    end,
  }
  return stack
end

return overrides
