-- Holds the shared ray during a trigger pull. Deliberate movement resumes aiming until the trigger is released.
local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/laser'

local triggerLock = {}

export type State =
  { read kind: 'ready' | 'escaped' }
  | {
    read kind: 'locked',
    read origin: vector,
    read direction: vector,
    read rawOrigin: vector,
    read rawDirection: vector,
    read surface: contracts.Surface,
  }

export type RawAim = { read origin: vector, read direction: vector }

export type Sample = {
  read raw: contracts.Input,
  read filtered: contracts.Input,
  read previous: contracts.Input?,
  read previousRaw: RawAim?,
  read hovered: contracts.Surface?,
  read grabbed: contracts.Surface?,
  read surfaces: { read [number]: contracts.Surface },
  read resetAfter: number,
}

local READY: { read kind: 'ready' } = { kind = 'ready' }
local ESCAPED: { read kind: 'escaped' } = { kind = 'escaped' }
table.freeze(READY)
table.freeze(ESCAPED)
local positive = schema.number { positive = true }
local descriptor = schema.object {
  enabled = schema.default(schema.boolean())(true),
  threshold = schema.default(schema.number { minimum = 0, maximum = 1 })(0.1),
  unlockAngle = schema.default(positive)(math.pi / 60),
  unlockDistance = schema.default(positive)(0.03),
}
local lockedFrame: (contracts.Input, State) -> contracts.Input
local offered: ({ read [number]: contracts.Surface }, contracts.Surface) -> boolean

function triggerLock.ready(): State
  return READY
end

function triggerLock.resolve(given: contracts.TriggerLockOverride?, base: contracts.TriggerLock): contracts.TriggerLock
  return descriptor.resolve(given, base, 'laser trigger lock')
end

function triggerLock.update(state: State, sample: Sample, settings: contracts.TriggerLock): (contracts.Input, State)
  local raw, filtered = sample.raw, sample.filtered
  local trigger = raw.trigger
  if trigger ~= nil and (type(trigger) ~= 'number' or trigger ~= trigger or trigger < 0 or trigger > 1) then
    error('laser: input trigger ranges from 0 to 1', 0)
  end
  if not settings.enabled or trigger == nil then
    return filtered, READY
  end
  local released: State = READY
  if trigger > settings.threshold then
    released = ESCAPED
  end
  local direction = raw.direction
  local length = direction:length()
  if raw.grip or sample.grabbed or length == 0 or (raw.dt ~= nil and raw.dt > sample.resetAfter) then
    return filtered, released
  end
  direction /= length
  if state.kind == 'locked' then
    if state.surface.dead or not offered(sample.surfaces, state.surface) then
      return filtered, released
    end
    local turn = math.acos(math.clamp(direction:dot(state.rawDirection), -1, 1))
    local displacement = (raw.origin - state.rawOrigin):length()
    if turn > settings.unlockAngle or displacement > settings.unlockDistance then
      return filtered, released
    end
    -- The release frame retains the locked position, so releasing cannot move a click onto a neighbour.
    return lockedFrame(filtered, state), if trigger > settings.threshold then state else READY
  end
  if trigger <= settings.threshold then
    return filtered, READY
  end
  if state.kind == 'escaped' then
    return filtered, state
  end
  local previous = sample.previous
  local previousRaw = sample.previousRaw
  local surface = sample.hovered
  if not previous or not previousRaw or not surface or surface.dead or not offered(sample.surfaces, surface) then
    return filtered, ESCAPED
  end
  local anchorLength = previousRaw.direction:length()
  if anchorLength == 0 then
    return filtered, ESCAPED
  end
  local anchorDirection = previousRaw.direction / anchorLength
  local turn = math.acos(math.clamp(direction:dot(anchorDirection), -1, 1))
  if turn > settings.unlockAngle or (raw.origin - previousRaw.origin):length() > settings.unlockDistance then
    return filtered, ESCAPED
  end
  local locked: State = {
    kind = 'locked',
    origin = previous.origin,
    direction = previous.direction,
    rawOrigin = previousRaw.origin,
    rawDirection = anchorDirection,
    surface = surface,
  }
  return lockedFrame(filtered, locked), locked
end

lockedFrame = function(frame: contracts.Input, state: State): contracts.Input
  assert(state.kind == 'locked')
  return {
    origin = state.origin,
    direction = state.direction,
    pose = frame.pose,
    trigger = frame.trigger,
    buttons = frame.buttons,
    grip = frame.grip,
    scrollX = frame.scrollX,
    scrollY = frame.scrollY,
    dt = frame.dt,
  }
end

offered = function(surfaces: { read [number]: contracts.Surface }, target: contracts.Surface): boolean
  for _, surface in surfaces do
    if surface == target then
      return true
    end
  end
  return false
end

return {
  schema = descriptor,
  ready = triggerLock.ready,
  resolve = triggerLock.resolve,
  update = triggerLock.update,
}
