-- Covers lua/lunette-plugins/input/laser/private/trigger-lock.luau: the ray hold during a trigger pull.

local testing = require '@testing'
local expect = testing.expect
local triggerLock = require '../private/trigger-lock'

local test = testing.suite()

local SETTINGS: any = { enabled = true, threshold = 0.1, unlockAngle = math.pi / 60, unlockDistance = 0.03 }
local RESET_AFTER = 10

local function input(overrides: { [string]: any }?): any
  local value: any = {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4(),
    trigger = 1,
    buttons = {},
    grip = false,
    scrollX = 0,
    scrollY = 0,
    dt = 1 / 90,
  }
  for key, field in overrides or {} do
    value[key] = field
  end
  return value
end

local function surface(): any
  return { dead = false }
end

local function sample(overrides: { [string]: any }): any
  local raw = overrides.raw or input()
  local filtered = overrides.filtered or raw
  local value: any = {
    raw = raw,
    filtered = filtered,
    previous = filtered,
    previousRaw = { origin = raw.origin, direction = raw.direction },
    hovered = overrides.hovered,
    grabbed = nil,
    surfaces = if overrides.hovered then { overrides.hovered } else {},
    resetAfter = RESET_AFTER,
    dragPress = false,
  }
  for key, field in overrides do
    value[key] = field
  end
  return value
end

test('a trigger press on a surface locks the ray until it moves', function()
  local target = surface()
  local raw = input()
  local filtered = input { origin = vector.pack(0.01, 0, 0) }
  local frame, state = triggerLock.update(
    triggerLock.ready(),
    sample {
      raw = raw,
      filtered = filtered,
      previous = filtered,
      hovered = target,
    },
    SETTINGS
  )
  expect.equal(state.kind, 'locked', 'the press locks')
  local x, y, z = frame.origin:unpack()
  expect.near(x, 0.01, 1e-6, 'the locked origin')
  expect.near(y, 0, 1e-6, 'the locked y')
  expect.near(z, 0, 1e-6, 'the locked z')
end)

test('a trigger press that begins on a drag control leaves the ray live', function()
  local target = surface()
  local raw = input()
  local filtered = input { origin = vector.pack(0.01, 0, 0) }
  local frame, state = triggerLock.update(
    triggerLock.ready(),
    sample {
      raw = raw,
      filtered = filtered,
      previous = filtered,
      hovered = target,
      dragPress = true,
    },
    SETTINGS
  )
  expect.equal(state.kind, 'dragging', 'the drag keeps the lock off')
  local x = frame.origin:unpack()
  expect.near(x, 0.01, 1e-6, 'the live ray follows the pointer')

  -- The drag outlives the control under the pointer, and the ray keeps moving with it.
  local moved = input { origin = vector.pack(0.1, 0, 0), direction = vector.pack(1, 0, 0) }
  local followed, still = triggerLock.update(
    state,
    sample {
      raw = moved,
      filtered = moved,
      previous = frame,
      hovered = nil,
      dragPress = false,
    },
    SETTINGS
  )
  expect.equal(still.kind, 'dragging', 'the held press stays live')
  local followedX = followed.origin:unpack()
  expect.near(followedX, 0.1, 1e-6, 'the ray follows the drag')

  local released = input { trigger = 0 }
  local _, ready = triggerLock.update(
    still,
    sample {
      raw = released,
      filtered = released,
      previous = followed,
      hovered = nil,
    },
    SETTINGS
  )
  expect.equal(ready.kind, 'ready', 'the release ends the drag press')
end)

test('a drag press below the trigger threshold never starts', function()
  local grabbed = surface()
  local raw = input { trigger = 0.05 }
  local frame, state = triggerLock.update(
    triggerLock.ready(),
    sample {
      raw = raw,
      filtered = raw,
      hovered = grabbed,
      dragPress = true,
    },
    SETTINGS
  )
  expect.equal(state.kind, 'ready', 'a press below the threshold stays ready')
  expect.equal(frame, raw, 'the frame passes through unchanged')
end)

return test
