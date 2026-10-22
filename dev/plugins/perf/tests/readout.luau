local testing = require '@testing'
local readout = require '../readout'
local metrics = require '../metrics'
local expect = testing.expect
local test = testing.suite()

local function observed(): metrics.Metrics
  local state = metrics.new(4)
  for index, interval in { 0.010, 0.012, 0.014 } do
    metrics.observe(state, {
      interval = interval,
      work = 0.005,
      prediction = 0.025,
      skipped = if index == 2 then 1 else 0,
      compositor = {
        frame = index,
        gpu = 0.001,
        cpu = 0.0005,
        presents = 1,
        mispresented = 0,
        dropped = index - 1,
        reprojecting = true,
      },
    })
  end
  return state
end

test('seconds format as milliseconds with two decimals', function()
  expect.equal(readout.milliseconds(0.0111111), '11.11 ms')
  expect.equal(readout.milliseconds(0), '0.00 ms')
end)

test('an empty window shows no rows and says there is no timing', function()
  local state = metrics.new(4)
  expect.equal(#readout.times(state), 0)
  local counts = readout.counts(state)
  expect.equal(#counts, 1)
  expect.equal(counts[1], 'No frame timing yet.')
end)

test('time rows show current, average, and maximum', function()
  local rows = readout.times(observed())
  expect.equal(#rows, 5, 'three application rows and two compositor rows')
  local interval = rows[1]
  expect.equal(interval.id, 'interval')
  expect.equal(interval.cells[1], 'Frame interval')
  expect.equal(interval.cells[2], '14.00 ms', 'current')
  expect.equal(interval.cells[3], '12.00 ms', 'average')
  expect.equal(interval.cells[4], '14.00 ms', 'maximum')
  expect.equal(rows[4].id, 'compositor-gpu')
end)

test('counts cover the window and name reprojection', function()
  local counts = readout.counts(observed())
  expect.equal(counts[1], 'Skipped refreshes: 1 in the last 3 frames.')
  expect.equal(counts[2], 'Dropped: 3, mispresented: 0 in the last 3 compositor frames.')
  expect.equal(counts[3], 'SteamVR is reprojecting.')
end)

test('a snapshot carries the interval series oldest first', function()
  local snapshot = readout.snapshot(observed(), { { label = 'scene', duration = 0.002 } })
  expect.equal(#snapshot.intervals, 3)
  expect.near(snapshot.intervals[1], 0.010, 1e-12)
  expect.equal(snapshot.passes[1].cells[2], '2.00 ms')
  expect.truthy(table.isfrozen(snapshot), 'a snapshot is not changed after it is published')
end)

return test
