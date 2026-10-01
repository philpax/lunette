-- Which saved slot each live window of an application holds.
--
-- A file saves an application's windows as numbered slots. A window holds a
-- slot from the moment its panel is created until the window dies, so a window
-- closed and reopened takes the slot it left. Answering which slot a window
-- would take is a pure query: only hold records anything.

local lunette = require '@lunette'

local slots = {}

type Held = { window: lunette.Window, appId: string, slot: number }

export type Slots = {
  -- The slot a window holds, or nil.
  read held: (Slots, lunette.Window) -> number?,
  -- The slot a window holds, or the one it would take: the lowest slot no live
  -- window of its application holds. Records nothing.
  read slotFor: (Slots, lunette.Window) -> number?,
  -- Records that a window holds its slot, and answers the slot.
  read hold: (Slots, lunette.Window) -> number?,
}

-- An application identity a slot can be keyed on, or nil.
function slots.appIdOf(window: lunette.Window): string?
  local appId = window.appId
  if type(appId) ~= 'string' or appId == '' then
    return nil
  end
  return appId
end

function slots.new(): Slots
  local holds: { [number]: Held } = {}

  local function live(entry: Held?): Held?
    if entry and not entry.window.dead then
      return entry
    end
    return nil
  end

  local function lowestFree(appId: string): number
    local used: { [number]: boolean } = {}
    for _, entry in pairs(holds) do
      if entry.appId == appId and not entry.window.dead then
        used[entry.slot] = true
      end
    end
    local slot = 1
    while used[slot] do
      slot += 1
    end
    return slot
  end

  local function held(_self: Slots, window: lunette.Window): number?
    local entry = live(holds[window.id])
    return entry and entry.slot
  end

  return {
    held = held,
    slotFor = function(self: Slots, window: lunette.Window): number?
      local appId = slots.appIdOf(window)
      if not appId then
        return nil
      end
      return held(self, window) or lowestFree(appId)
    end,
    hold = function(self: Slots, window: lunette.Window): number?
      local appId = slots.appIdOf(window)
      if not appId or window.dead then
        return nil
      end
      local existing = held(self, window)
      if existing then
        return existing
      end
      for identity, entry in pairs(holds) do
        if entry.window.dead then
          holds[identity] = nil
        end
      end
      local slot = lowestFree(appId)
      holds[window.id] = { window = window, appId = appId, slot = slot }
      return slot
    end,
  }
end

return slots
