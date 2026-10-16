-- Near touch for a tracked fingertip: a pure state machine from per-frame depth samples to pointer events.
-- The defaults are the starting points that the input design gives for tuning in a headset.

local poke = {}

poke.HOVER_ENTRY = 0.03
poke.HOVER_EXIT = 0.05
poke.ACTIVATION = 0.002
poke.RELEASE_GAP = 0.003
poke.REARM_GAP = 0.003
poke.GRACE = 0.15

-- A panel under the fingertip: its key, the point in panel coordinates, and the fingertip's height above the rest
-- surface of the node under it, positive in front.
export type Candidate = {
  read panel: any,
  read x: number,
  read y: number,
  read depth: number,
  -- The rest surface's height above the panel, which the fingertip proxy is held at.
  read surface: number?,
}

export type Event = {
  read kind: 'enter' | 'move' | 'press' | 'release' | 'leave' | 'cancel',
  read panel: any,
  read x: number?,
  read y: number?,
}

export type Hand = {
  panel: any?,
  pressed: boolean,
  -- Whether a press may start: the fingertip entered from the front or moved back towards the surface after a
  -- release.
  armed: boolean,
  deepest: number,
  -- Whether the last press released on this hover, and the shallowest depth since, from which moving back towards
  -- the surface by the re-arm gap re-arms.
  released: boolean,
  shallowest: number,
  -- The depth in front of each panel on the previous frame, to tell an entry from the front.
  previous: { [any]: number },
  untracked: number,
}

function poke.new(): Hand
  return {
    panel = nil,
    pressed = false,
    armed = false,
    deepest = 0,
    released = false,
    shallowest = 0,
    previous = {},
    untracked = 0,
  }
end

local function emit(events: { Event }, event: Event): ()
  events[#events + 1] = event
end

-- Ends the hover. A press in progress is cancelled rather than released, so it does not activate.
local function leave(hand: Hand, events: { Event }): ()
  local panel = hand.panel
  if panel == nil then
    return
  end
  emit(events, { kind = if hand.pressed then 'cancel' else 'leave', panel = panel })
  hand.panel, hand.pressed, hand.armed = nil, false, false
end

-- Advances the hand by one frame. Candidates are the panels under the fingertip; nil means the hand is untracked.
function poke.step(hand: Hand, candidates: { Candidate }?, dt: number): { Event }
  local events: { Event } = {}
  if candidates == nil then
    hand.untracked += dt
    if hand.untracked > poke.GRACE then
      leave(hand, events)
      -- After the grace period a returning fingertip must enter from the front again.
      table.clear(hand.previous)
    end
    return events
  end
  hand.untracked = 0
  local current: Candidate? = nil
  for _, candidate in candidates do
    if candidate.panel == hand.panel then
      current = candidate
    end
  end
  -- A press ends on recoil before the hover is tested, so a fingertip pulled straight out releases rather than
  -- cancels.
  if current and hand.pressed then
    hand.deepest = math.min(hand.deepest, current.depth)
    if current.depth - hand.deepest >= poke.RELEASE_GAP or current.depth > 0 then
      hand.pressed, hand.armed, hand.released = false, false, true
      hand.shallowest = current.depth
      emit(events, { kind = 'release', panel = current.panel, x = current.x, y = current.y })
    end
  end
  if hand.panel ~= nil and (current == nil or current.depth > poke.HOVER_EXIT) then
    leave(hand, events)
    current = nil
  end
  if hand.panel == nil then
    for _, candidate in candidates do
      if candidate.depth <= poke.HOVER_ENTRY and (current == nil or candidate.depth < current.depth) then
        current = candidate
      end
    end
    if current then
      local before = hand.previous[current.panel]
      hand.panel = current.panel
      hand.pressed, hand.released = false, false
      hand.armed = before ~= nil and before > poke.HOVER_ENTRY
      hand.shallowest = current.depth
      emit(events, { kind = 'enter', panel = current.panel, x = current.x, y = current.y })
    end
  end
  table.clear(hand.previous)
  for _, candidate in candidates do
    hand.previous[candidate.panel] = candidate.depth
  end
  if current == nil then
    return events
  end
  local depth = current.depth
  emit(events, { kind = 'move', panel = current.panel, x = current.x, y = current.y })
  if hand.pressed then
    return events
  end
  hand.shallowest = math.max(hand.shallowest, depth)
  if not hand.armed then
    -- Retreating past the entry distance arms; after a release, so does moving back towards the surface.
    local returned = hand.released and hand.shallowest - depth >= poke.REARM_GAP
    if depth > poke.HOVER_ENTRY or returned then
      hand.armed, hand.released = true, false
    end
  end
  if hand.armed and depth <= -poke.ACTIVATION then
    hand.pressed = true
    hand.deepest = depth
    emit(events, { kind = 'press', panel = current.panel, x = current.x, y = current.y })
  end
  return events
end

return poke
