-- Stabilizes the shared picking and drawing ray without changing the pose used for spatial grabs.
local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/laser'

local aim = {}

export type State = {
  origin: vector,
  direction: vector,
  rawOrigin: vector,
  rawDirection: vector,
  originVelocity: vector,
  directionVelocity: vector,
}

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }
local descriptor = schema.object {
  enabled = schema.default(schema.boolean())(true),
  minCutoff = schema.default(positive)(2),
  derivativeCutoff = schema.default(positive)(5),
  angularBeta = schema.default(nonnegative)(4),
  positionBeta = schema.default(nonnegative)(40),
  resetAfter = schema.default(positive)(0.2),
}
local ray = schema.object { origin = schema.vector(), direction = schema.vector() }
local coefficient: (number, number) -> number
local magnitude: (vector) -> number

function aim.resolve(given: contracts.AimOverride?, base: contracts.Aim): contracts.Aim
  return descriptor.resolve(given, base, 'laser aim')
end

function aim.update(previous: State?, frame: contracts.Input, settings: contracts.Aim): (contracts.Input, State?)
  ray.parse({ origin = frame.origin, direction = frame.direction }, 'laser input')
  local dt = frame.dt
  if dt ~= nil and (type(dt) ~= 'number' or dt ~= dt or dt < 0 or dt == math.huge) then
    error('laser: input dt is a finite nonnegative number', 0)
  end
  local length = magnitude(frame.direction)
  if not settings.enabled or length == 0 then
    return frame, nil
  end
  local direction = frame.direction / length
  local state: State
  if not previous or not dt or dt == 0 or dt > settings.resetAfter then
    state = {
      origin = frame.origin,
      direction = direction,
      rawOrigin = frame.origin,
      rawDirection = direction,
      originVelocity = vector.pack(0, 0, 0),
      directionVelocity = vector.pack(0, 0, 0),
    }
  else
    local derivativeAlpha = coefficient(settings.derivativeCutoff, dt)
    local originVelocity = previous.originVelocity
      + ((frame.origin - previous.rawOrigin) / dt - previous.originVelocity) * derivativeAlpha
    local directionVelocity = previous.directionVelocity
      + ((direction - previous.rawDirection) / dt - previous.directionVelocity) * derivativeAlpha
    local positionAlpha = coefficient(settings.minCutoff + settings.positionBeta * magnitude(originVelocity), dt)
    local angularAlpha = coefficient(settings.minCutoff + settings.angularBeta * magnitude(directionVelocity), dt)
    local filtered = previous.direction + (direction - previous.direction) * angularAlpha
    local filteredLength = magnitude(filtered)
    state = {
      origin = previous.origin + (frame.origin - previous.origin) * positionAlpha,
      -- Opposite directions can cancel at the midpoint, so the filter reacquires instead of emitting a zero ray.
      direction = if filteredLength > 0.000001 then filtered / filteredLength else direction,
      rawOrigin = frame.origin,
      rawDirection = direction,
      originVelocity = originVelocity,
      directionVelocity = directionVelocity,
    }
  end
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
  },
    state
end

coefficient = function(cutoff: number, dt: number): number
  return 1 / (1 + 1 / (2 * math.pi * cutoff * dt))
end

magnitude = function(value: vector): number
  local length = value:length()
  if length ~= length or length == math.huge then
    error('laser: aim magnitude is finite', 0)
  end
  return length
end

return { schema = descriptor, resolve = aim.resolve, update = aim.update }
