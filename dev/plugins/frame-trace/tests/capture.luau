local testing = require '@testing'
local capture = require '../private/capture'
local expect = testing.expect
local test = testing.suite()

local function record(sequence: number, seconds: number): capture.Record
  return {
    sequence = sequence,
    syncTime = seconds,
    interval = 0.011,
    update = 0.001,
    draw = 0.002,
    graphicsSubmit = 0.0003,
    headsetSubmit = 0.0004,
    present = 0.0001,
    gc = 0.0002,
    observer = 0.00001,
    heapSync = 200,
    heapUpdate = 220,
    heapDraw = 210,
    heapGraphicsSubmit = 211,
    heapHeadsetSubmit = 212,
    heapPresent = 213,
    heapGc = 190,
    active = true,
    visible = true,
    focused = false,
    nativeInterval = 0.011,
    nativeWork = 0.004,
    skipped = 0,
    refreshRate = 90,
    gcBudgetUs = 200,
    executionMode = 'tiered',
    sync = 0.007,
    gpuTiming = false,
    supersample = 1,
    antialias = true,
    foveation = 'low',
  }
end

test('a finite capture stops at the duration and never grows beyond its preallocated capacity', function()
  for capacity = 1, 8 do
    local state = capture.new(capacity, 0.025)
    local slots = state.rows
    for index = 1, capacity + 5 do
      capture.observe(state, record(index, index * 0.011))
    end
    expect.equal(state.rows, slots)
    expect.equal(#state.rows, capacity)
    expect.equal(state.count, math.min(capacity, 4))
    expect.equal(state.status, 'complete')
  end
end)

test('stopping keeps complete rows and cancellation discards them', function()
  local state = capture.new(4, 30)
  capture.observe(state, record(7, 1))
  capture.stop(state)
  capture.observe(state, record(8, 2))
  expect.equal(state.count, 1)
  expect.equal(state.status, 'stopped')
  capture.cancel(state)
  expect.equal(state.count, 0)
  expect.equal(state.status, 'cancelled')
  expect.raises(function()
    capture.csv(state)
  end, 'no completed capture')
end)

test('capture copies coherent public records and retains missing values as empty CSV fields', function()
  local state = capture.new(2, 30)
  local row = record(19, 2)
  row.nativeInterval = nil
  row.skipped = nil
  capture.observe(state, row)
  row.update = 999
  capture.stop(state)
  local csv = capture.csv(state)
  expect.truthy(csv:find('formatVersion,sequence,syncTime,sync,interval,update', 1, true))
  expect.truthy(csv:find('1,19,2,0.007,0.011,0.001', 1, true))
  expect.truthy(csv:find('false,,0.004,,90,200,false,1,true,low,tiered', 1, true))
  expect.truthy(csv:find('heapSyncKiB', 1, true), 'heap units are explicit')
end)

test('invalid bounds and nonfinite public timing values are rejected', function()
  expect.raises(function()
    capture.new(0, 1)
  end, 'capacity')
  expect.raises(function()
    capture.new(10001, 1)
  end, 'capacity')
  expect.raises(function()
    capture.new(1, math.huge)
  end, 'duration')
  local state = capture.new(1, 1)
  local row = record(1, 1)
  row.draw = 0 / 0
  expect.raises(function()
    capture.observe(state, row)
  end, 'draw')
end)

return test
