local testing = require '@testing'
local metrics = require '../metrics'
local history = require '../history'
local expect = testing.expect
local test = testing.suite()

local function compositor(frame: number, dropped: number?): metrics.Compositor
  return {
    frame = frame,
    gpu = 0.002,
    cpu = 0.001,
    presents = 1,
    mispresented = 1,
    dropped = dropped or 0,
    reprojecting = frame % 2 == 0,
  }
end

local function timing(skipped: number, frame: number?): metrics.FrameTiming
  return {
    interval = 0.011,
    work = 0.006,
    prediction = 0.03,
    skipped = skipped,
    compositor = if frame then compositor(frame, 2) else nil,
  }
end

test('no timing records nothing', function()
  local state = metrics.new(8)
  metrics.observe(state, nil)
  expect.equal(history.count(state.interval), 0)
  expect.equal(state.compositor, false)
end)

test('application series take one sample per observed frame', function()
  local state = metrics.new(8)
  metrics.observe(state, timing(0))
  metrics.observe(state, timing(2))
  expect.equal(history.count(state.interval), 2)
  expect.equal(history.sum(state.skipped), 2, 'skipped refreshes add over the window')
  expect.equal(state.compositor, false, 'timing without the runtime carries no compositor statistics')
  expect.equal(history.count(state.gpu), 0)
end)

test('a compositor frame reported again is counted once', function()
  local state = metrics.new(8)
  metrics.observe(state, timing(0, 10))
  metrics.observe(state, timing(0, 10))
  metrics.observe(state, timing(0, 11))
  expect.equal(history.count(state.interval), 3, 'every application frame samples')
  expect.equal(history.count(state.gpu), 2, 'each compositor frame samples once')
  expect.equal(history.sum(state.dropped), 4, 'dropped frames are not counted twice')
  expect.equal(history.sum(state.mispresented), 2)
  expect.equal(state.reprojecting, false, 'the latest compositor frame decides reprojection')
  metrics.observe(state, timing(0, 12))
  expect.equal(state.reprojecting, true)
end)

test('a timing without compositor statistics clears reprojection but keeps the compositor history', function()
  local state = metrics.new(8)
  metrics.observe(state, timing(0, 12))
  metrics.observe(state, timing(0))
  expect.equal(state.compositor, false)
  expect.equal(state.reprojecting, false)
  expect.equal(history.count(state.gpu), 1)
end)

test('pass durations add by label, longest first, with unlabelled passes together', function()
  local a, b, c, d = {}, {}, {}, {}
  local labels = { [a] = 'scene', [b] = 'scene', [c] = nil, [d] = 'overlay' }
  local passes = metrics.passes({
    [a] = { duration = 0.001 },
    [b] = { duration = 0.002 },
    [c] = { duration = 0.0005 },
    [d] = { duration = 0.0005 },
  }, function(pass: any): string?
    return labels[pass]
  end)
  expect.equal(#passes, 3)
  expect.equal(passes[1].label, 'scene')
  expect.near(passes[1].duration, 0.003, 1e-12, 'scene passes add')
  expect.equal(passes[2].label, 'overlay', 'equal durations order by label')
  expect.equal(passes[3].label, metrics.UNLABELLED)
end)

test('no passes give an empty list', function()
  expect.equal(#metrics.passes({}, function(): string?
    return nil
  end), 0)
end)

return test
