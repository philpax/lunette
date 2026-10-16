-- Feeds tracked fingertips to the near-touch state machine and delivers its events through the pointer router, as
-- a ray's events are delivered. Bare hands have no actuator, so their pointers report no haptics.
-- This path is implemented against the design without hand-tracking hardware to test it on.

local vocabulary = require '@lunette-contracts/vocabulary'
local records = require './records'
local input = require './input'
local poke = require './poke'

local touch = {}

-- The index fingertip in LÖVR's hand skeleton.
local INDEX_TIP = 11
-- Panels further behind the fingertip than this are not candidates.
local BEHIND = 0.05

-- Where a hovering fingertip's proxy draws: the point on its panel, the rest surface beneath it, and its depth.
export type Marker = {
  panel: records.Panel,
  x: number,
  y: number,
  surface: number,
  depth: number,
}

export type Touch = {
  hands: { [string]: poke.Hand },
  pointers: { [string]: vocabulary.Pointer },
  markers: { [string]: Marker },
}

function touch.new(): Touch
  local pointers: { [string]: vocabulary.Pointer } = {}
  for _, hand in { 'left', 'right' } do
    local pointer = {
      vibrate = function(): boolean
        return false
      end,
    }
    pointers[hand] = pointer :: any
  end
  return { hands = { left = poke.new(), right = poke.new() }, pointers = pointers, markers = {} }
end

-- The fingertip of a tracked bare hand, from the runtime's poke pose or the skeleton, or nil.
local function fingertip(hand: 'left' | 'right'): vector?
  local headset = lovr.headset
  if not headset or not headset.getSkeleton then
    return nil
  end
  local device: 'hand/left' | 'hand/right' = if hand == 'left' then 'hand/left' else 'hand/right'
  if not headset.isTracked(device) then
    return nil
  end
  local skeleton = headset.getSkeleton(device)
  if not skeleton then
    -- No skeleton means a controller rather than a bare hand.
    return nil
  end
  if headset.getHandPose then
    local x, y, z = headset.getHandPose(hand, 'poke')
    if x ~= 0 or y ~= 0 or z ~= 0 then
      return vector.pack(x, y, z)
    end
  end
  local tip = skeleton[INDEX_TIP]
  if not tip then
    return nil
  end
  return vector.pack(tip[1], tip[2], tip[3])
end

-- The panels in front of or just behind the fingertip, with the depth above the rest surface of the node under it.
function touch.candidates(panels: { records.Panel }, env: records.Environment, point: vector): { poke.Candidate }
  local list: { poke.Candidate } = {}
  for _, panel in panels do
    if panel.visible and not panel.dead and panel.width > 0 then
      local inverse = lovr.math.mat4(panel.pose):invert()
      local lx, ly, lz = inverse:mul(point.x, point.y, point.z)
      local x, y = lx + panel.width / 2, panel.height / 2 - ly
      if x >= 0 and y >= 0 and x <= panel.width and y <= panel.height and lz > -BEHIND then
        local node = input.target(panel, env, x, y) or input.deepest(panel, x, y)
        local surface = if node then node.z - node.lift else 0
        table.insert(list, { panel = panel, x = x, y = y, depth = lz - surface, surface = surface })
      end
    end
  end
  return list
end

function touch.update(
  state: Touch,
  panels: { records.Panel },
  env: records.Environment,
  router: input.Router,
  dt: number
): ()
  for name, hand in state.hands do
    local point = fingertip(name :: any)
    local candidates = if point then touch.candidates(panels, env, point) else nil
    state.markers[name] = nil
    for _, candidate in candidates or {} do
      if candidate.panel == hand.panel then
        local panel = candidate.panel :: records.Panel
        state.markers[name] = {
          panel = panel,
          x = candidate.x,
          y = candidate.y,
          surface = candidate.surface or 0,
          depth = candidate.depth,
        }
      end
    end
    for _, event in poke.step(hand, candidates, dt) do
      local panel = event.panel :: records.Panel
      if not panel.dead then
        local delivered: any = {
          kind = event.kind,
          pointer = state.pointers[name],
          x = event.x,
          y = event.y,
          captured = false,
          inside = true,
          button = 'left',
          reason = if event.kind == 'cancel' then 'tracking-loss' else nil,
        }
        input.pointer(router, panel, env, delivered)
      end
    end
  end
end

return touch
