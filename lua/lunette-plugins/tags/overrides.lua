-- Owner-held overrides of one value, the most recent live one deciding.
--
-- Each owner holds at most one override. Setting it again moves it to the
-- top and changes its value. An override is an effect of its owner, so it
-- ends when the owner unloads; the value then falls back to the most recent
-- override left, or to the fallback when none is. Reverting to the value
-- from before an override is not what happens, because that would depend on
-- the order owners unload in.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local overrides = {}

type Owner = owner.Owner

type Entry<T> = { owner: Owner, value: T, effect: plugin.Effect? }

export type Stack<T> = {
  -- Sets the owner's override, and answers whether the decided value changed.
  read set: (Stack<T>, Owner, T) -> boolean,
  -- The decided value.
  read value: (Stack<T>) -> T,
  -- Forgets every override and answers their effects, for the caller to
  -- dispose once its own state is consistent.
  read clear: (Stack<T>) -> { plugin.Effect },
}

-- A stack whose overrides are acquired through context. changed runs when an
-- override that ends changes the decided value; a set answers the change to
-- its caller instead.
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
