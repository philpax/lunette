-- Holds stable slots for live windows of each saved identity.
local lunette = require '@lunette'

local slots = {}

type Held = { window: lunette.Window, key: string, slot: number }

export type Identified =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }

-- The identity saved state is keyed on, or nil for one that is not saved.
export type KeyFor = (Identified) -> string?

export type Slots = {
  read key: (Slots, Identified) -> string?,
  read held: (Slots, lunette.Window) -> number?,
  -- Returns the held slot or lowest free slot without recording it.
  read slotFor: (Slots, lunette.Window) -> number?,
  read hold: (Slots, lunette.Window) -> number?,
}

-- Uses a window application id or monitor id when it is a non-empty string.
function slots.defaultKey(target: Identified): string?
  if target.source.dead then
    return nil
  end
  local key: unknown
  if target.kind == 'window' then
    key = (target.source :: lunette.Window).appId
  else
    key = (target.source :: lunette.Monitor).id
  end
  if type(key) ~= 'string' or key == '' then
    return nil
  end
  return key
end

function slots.new(keyFor: KeyFor?): Slots
  local identify: KeyFor = keyFor or slots.defaultKey
  local holds: { [number]: Held } = {}

  local function key(target: Identified): string?
    local answered = identify(target)
    if answered ~= nil and (type(answered) ~= 'string' or answered == '') then
      error('desktop.persist: keyFor answers a non-empty string or nil, not ' .. tostring(answered), 0)
    end
    return answered
  end

  local function windowKey(window: lunette.Window): string?
    return key { kind = 'window', source = window }
  end

  local function live(entry: Held?): Held?
    if entry and not entry.window.dead then
      return entry
    end
    return nil
  end

  local function lowestFree(identity: string): number
    local used: { [number]: boolean } = {}
    for _, entry in pairs(holds) do
      if entry.key == identity and not entry.window.dead then
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
    key = function(_self: Slots, target: Identified): string?
      return key(target)
    end,
    held = held,
    slotFor = function(self: Slots, window: lunette.Window): number?
      local identity = windowKey(window)
      if not identity then
        return nil
      end
      return held(self, window) or lowestFree(identity)
    end,
    hold = function(self: Slots, window: lunette.Window): number?
      local identity = if window.dead then nil else windowKey(window)
      if not identity then
        return nil
      end
      local existing = held(self, window)
      if existing then
        return existing
      end
      for windowId, entry in pairs(holds) do
        if entry.window.dead then
          holds[windowId] = nil
        end
      end
      local slot = lowestFree(identity)
      holds[window.id] = { window = window, key = identity, slot = slot }
      return slot
    end,
  }
end

return slots
