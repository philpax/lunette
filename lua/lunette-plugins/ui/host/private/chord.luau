-- The default-appearance chord: both thumbstick clicks held together for a moment toggle default appearance once
-- per hold.

local chord = {}

-- Seconds both clicks are held before the chord fires. It is long enough that pressing both sticks by accident
-- while traversing does not toggle the interface.
chord.HOLD = 1.5

export type Chord = { held: number, fired: boolean }

function chord.new(): Chord
  return { held = 0, fired = false }
end

-- Advances the chord by a frame and answers whether it fired on this frame.
function chord.step(state: Chord, left: boolean, right: boolean, dt: number): boolean
  if not (left and right) then
    state.held = 0
    state.fired = false
    return false
  end
  state.held += dt
  if state.fired or state.held < chord.HOLD then
    return false
  end
  state.fired = true
  return true
end

-- Reads both controllers' thumbstick clicks through the headset module, when one is loaded.
function chord.read(): (boolean, boolean)
  local headset = lovr.headset
  if not headset or not headset.isDown or not headset.isTracked then
    return false, false
  end
  local function down(device: 'hand/left' | 'hand/right'): boolean
    return headset.isTracked(device) and headset.isDown(device, 'thumbstick') == true
  end
  return down 'hand/left', down 'hand/right'
end

return chord
