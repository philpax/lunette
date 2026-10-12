local testing = require '@testing'
local expect = testing.expect
local envelope = require '../envelope'
local test = testing.suite()
type Feature = envelope.Feature
type Values = envelope.Values

local function feature(level: number, onset: number?): Feature
  return { bass = level, mid = level, treble = level, rms = level, peak = level, onset = onset or 0 }
end

local function copy(values: Values): Values
  return table.clone(values)
end

local function unchanged(actual: Values, wanted: Values): ()
  for key, value in wanted do
    expect.equal(actual[key], value, 'continuous response ' .. key)
  end
end

test('response_crossfade_is_continuous', function()
  local response = envelope.new()
  local values = response.values
  response:switchSource 'first'
  response:consume(feature(0.8, 1))
  expect.equal(response:step(0), values, 'the response table is reused')
  expect.equal(values.bass, 0, 'the initial switch has no jump')
  response:step(2)
  expect.near(values.bass, 0.8, 1e-12, 'the settled source response')
  local previous = copy(values)
  response:switchSource 'second'
  unchanged(response:step(0), previous)
  response:consume(feature(0.2))
  response:step(0.001)
  expect.truthy(math.abs(values.bass - previous.bass) < 0.001, 'a small step has a small change')
  response:step(0.599)
  expect.near(
    values.bass,
    previous.bass * 0.5 + 0.2 * (1 - math.exp(-0.6 / 0.06)) * 0.5,
    1e-12,
    'the halfway feature crossfade'
  )
  previous = copy(values)
  response:switchSource 'third'
  unchanged(response:step(0), previous)
  response:consume(feature(1))
  response:step(1.2)
  expect.near(values.bass, 1 - math.exp(-1.2 / 0.06), 1e-12, 'an interrupted fade settles at the new source')
  previous = copy(values)
  response:switchSource(nil)
  unchanged(response:step(0), previous)
  response:consume(feature(1, 1))
  response:step(0.75)
  expect.near(values.bass, previous.bass / 2, 1e-12, 'halfway through the loss fade')
  response:switchSource(nil)
  response:step(0.75)
  for key, value in values do
    expect.equal(value, 0, 'the loss fade finishes at zero ' .. key)
  end
end)

test('attack release and onset waves follow elapsed time and preserve multiple hop impulses', function()
  local response = envelope.new { crossfade = 0.001 }
  response:switchSource 'source'
  response:step(0.001)
  response:consume(feature(1))
  response:step(0.06)
  expect.near(response.values.bass, 1 - math.exp(-1), 1e-12, 'the attack time constant')
  local level = response.values.bass
  response:consume(feature(0))
  response:step(0.45)
  expect.near(response.values.bass, level * math.exp(-1), 1e-12, 'the release time constant')
  response:consume(feature(0, 0.2))
  response:consume(feature(0, 0.9))
  response:consume(feature(0, 0.1))
  response:step(0.01)
  expect.equal(response.values.onset, 0.9, 'the strongest completed onset survives the render frame')
  expect.equal(response.values.waves, 0.9, 'the onset wave starts at the strongest impulse')
  response:step(0.45)
  expect.equal(response.values.onset, 0, 'onset is an impulse')
  expect.near(response.values.waves, 0.9 * math.exp(-1), 1e-12, 'the onset wave decay')
  local whole, fragmented = envelope.new(), envelope.new()
  for _, current in { whole, fragmented } do
    current:switchSource 'source'
    current:consume(feature(0.7))
  end
  whole:step(0.6)
  for _ = 1, 60 do
    fragmented:step(0.01)
  end
  expect.near(fragmented.values.bass, whole.values.bass, 1e-12, 'constant-input envelopes are dt-partition invariant')
end)

test('consuming a feature copies values without retaining the caller table', function()
  local response = envelope.new { crossfade = 0.001 }
  response:switchSource 'source'
  response:step(0.001)
  local input = feature(0.6, 0.7)
  response:consume(input)
  input.bass, input.mid, input.treble, input.rms, input.peak, input.onset = 0, 0, 0, 0, 0, 0
  response:step(0.06)
  expect.near(response.values.bass, 0.6 * (1 - math.exp(-1)), 1e-12, 'the copied feature')
  expect.equal(response.values.onset, 0.7, 'the copied onset')
end)

test('invalid dt and features remain finite bounded and do not consume pending onsets', function()
  local response = envelope.new { crossfade = 0.001 }
  response:switchSource 'source'
  response:step(0.001)
  response:consume(feature(0.5, 0.75))
  local before = copy(response.values)
  for _, dt in { 0, -1, math.huge, -math.huge, 0 / 0 } do
    unchanged(response:step(dt), before)
  end
  response:step(0.06)
  expect.equal(response.values.onset, 0.75, 'invalid dt retains pending onsets')
  response:consume {
    bass = 0 / 0,
    mid = math.huge,
    treble = -math.huge,
    rms = -1,
    peak = 2,
    onset = 0 / 0,
  }
  response:step(1e100)
  for key, value in response.values do
    expect.truthy(value == value and value >= 0 and value <= 1, 'finite bounded ' .. key)
  end
  expect.equal(response.values.peak, 1, 'large features clamp')
  for _, config in { { attack = 0 }, { release = -1 }, { crossfade = math.huge }, { loss = 0 / 0 } } do
    expect.raises(function()
      envelope.new(config)
    end, 'audio envelope:')
  end
end)

return test
