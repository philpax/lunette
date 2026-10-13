local testing = require '@testing'
local expect = testing.expect
local config = require '../config'
local model = require '../model'

local test = testing.suite()

local function new(given: config.Config?): model.State
  return model.new(config.schema.parse(given or {}))
end

test('visibility_fade_reversals', function()
  local state = new()
  expect.equal(state:update(0, false).visibility, 0, 'starts fully transparent')
  expect.near(state:update(0.4, false).visibility, 0.5, 1e-8, 'half fade')
  expect.near(state:update(0.2, true).visibility, 0.25, 1e-8, 'primary visibility reverses continuously')
  expect.near(state:update(0.1, false).visibility, 0.375, 1e-8, 'second reversal continues from current value')
  state:setEnabled(false)
  expect.near(state:update(0.1, false).visibility, 0.25, 1e-8, 'disabled uses the same fade')
  state:setEnabled(true)
  expect.equal(state:update(1, false).visibility, 1, 'completed visible fade')
  expect.equal(state:update(1, true).visibility, 0, 'completed hidden fade')
end)

test('invalid deltas and feature values preserve finite bounded state', function()
  local state = new()
  state:setFeatures({ bass = math.huge, mid = -2, treble = 0 / 0 }, {
    { strength = math.huge },
    { strength = 5, position = -2 },
  })
  for _, dt in { 0 / 0, math.huge, -math.huge, -1, 0, 1e300, 0.01 } do
    local frame = state:update(dt, false)
    for _, value in { frame.visibility, frame.time, frame.bass, frame.mid, frame.treble, frame.brightness } do
      expect.truthy(value == value and math.abs(value) < math.huge, 'finite value')
    end
    expect.truthy(frame.visibility >= 0 and frame.visibility <= 1, 'visibility bounds')
    expect.truthy(frame.brightness >= 0 and frame.brightness <= 1, 'brightness bounds')
  end
  expect.equal(new({ fadeDuration = 0 }):update(0, false).visibility, 1, 'explicit immediate fade')
end)

test('repeated audio loss settles without interrupting autonomous motion', function()
  local state = new { response = 1, attackDuration = 0 }
  state:setFeatures { bass = 1, mid = 0.6, treble = 0.2 }
  local before = state:update(1, false)
  state:noAudio()
  local half = state:update(0.75, false)
  state:noAudio()
  expect.near(half.bass, before.bass / 2, 1e-8, 'half loss settling interval')
  local settled = state:update(0.75, false)
  expect.equal(settled.bass, 0, 'repeated loss does not restart settling')
  expect.equal(settled.visibility, 1, 'audio loss does not hide the backdrop')
  expect.truthy(settled.time > before.time, 'autonomous clock continues without audio')
end)

test('visibility evolution is invariant to frame partitioning', function()
  for _, parts in { 1, 2, 5, 17, 64 } do
    local state = new()
    local frame
    for _ = 1, parts do
      frame = state:update(0.36 / parts, false)
    end
    expect.near(frame.visibility, 0.45, 1e-7, 'partitioned visible interval')
    for _ = 1, parts do
      frame = state:update(0.16 / parts, true)
    end
    expect.near(frame.visibility, 0.25, 1e-7, 'partitioned reversal')
  end
end)

test('response attack and release use independently configured exponential durations', function()
  local state = new { response = 1 }
  state:setFeatures { bass = 1, mid = 1, treble = 1 }
  local attack = state:update(0.12, false)
  expect.near(attack.bass, 1 - math.exp(-1), 1e-8, '120 millisecond attack time constant')
  state:setFeatures { bass = 0, mid = 0, treble = 0 }
  local release = state:update(0.45, false)
  expect.near(release.bass, attack.bass * math.exp(-1), 1e-8, '450 millisecond release time constant')
  local immediate = new { response = 1, attackDuration = 0, releaseDuration = 0 }
  immediate:setFeatures { bass = 1, mid = 0, treble = 0 }
  expect.equal(immediate:update(0.01, false).bass, 1, 'explicit immediate attack')
  immediate:setFeatures { bass = 0, mid = 0, treble = 0 }
  expect.equal(immediate:update(0.01, false).bass, 0, 'explicit immediate release')
end)

test('aged onsets and runtime strengths stay finite and make bounded discards explicit', function()
  local state = new()
  state:setStrengths(0.25, 0)
  state:setFeatures({ bass = 1, mid = 1, treble = 1 }, {
    { strength = 1, age = 0.75, position = 0.5 },
    { strength = 1, age = 3 },
    { strength = 1, age = math.huge },
  })
  local frame = state:update(0.1, false)
  expect.equal(#frame.waves, 1, 'expired or invalid-aged waves are not delivered')
  expect.near(frame.waves[1].age, 0.85, 1e-8, 'age includes native sample delay')
  expect.equal(frame.responseStrength, 0.25, 'dynamic strength reaches renderer')
  expect.equal(frame.time, 0, 'motion control changes autonomous clock')
  state:setFeatures({ bass = 0, mid = 0, treble = 0 }, {}, { gap = 'capacity', discardedHops = 4 })
  expect.equal(#state.waves, 0, 'explicit gap clears stale impulses')
  expect.equal(state.discardedHops, 4, 'discard count remains observable')
end)

return test
