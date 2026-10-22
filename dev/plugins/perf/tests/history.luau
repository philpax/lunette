local testing = require '@testing'
local history = require '../history'
local expect = testing.expect
local test = testing.suite()

local function same(actual: { number }, wanted: { number }, context: string): ()
  expect.equal(#actual, #wanted, context .. ': the length')
  for index, value in wanted do
    expect.equal(actual[index], value, `{context}: sample {index}`)
  end
end

test('an empty history has no latest, mean, or maximum', function()
  local ring = history.new(4)
  expect.equal(history.count(ring), 0)
  expect.equal(history.latest(ring), nil)
  expect.equal(history.mean(ring), nil)
  expect.equal(history.maximum(ring), nil)
  expect.equal(history.sum(ring), 0)
  same(history.values(ring), {}, 'no values')
end)

test('a history of one sample holds only the newest', function()
  local ring = history.new(1)
  history.push(ring, 3)
  history.push(ring, 5)
  expect.equal(history.count(ring), 1)
  expect.equal(history.latest(ring), 5)
  same(history.values(ring), { 5 }, 'the newest sample')
end)

test('a full history drops the oldest sample and keeps its order', function()
  local ring = history.new(3)
  for value = 1, 5 do
    history.push(ring, value)
  end
  same(history.values(ring), { 3, 4, 5 }, 'the last three')
  expect.equal(history.latest(ring), 5)
  expect.equal(history.maximum(ring), 5)
  expect.equal(history.mean(ring), 4)
  expect.equal(history.sum(ring), 12)
end)

test('every push sequence agrees with the tail of the same sequence', function()
  -- A fixed seed keeps the generated sequences the same on every run.
  math.randomseed(7)
  for _ = 1, 200 do
    local capacity = math.random(1, 8)
    local ring = history.new(capacity)
    local pushed: { number } = {}
    for _ = 1, math.random(0, 20) do
      local value = math.random(-50, 50)
      history.push(ring, value)
      table.insert(pushed, value)
      local tail = table.move(pushed, math.max(1, #pushed - capacity + 1), #pushed, 1, {})
      same(history.values(ring), tail, `capacity {capacity}`)
      expect.equal(history.latest(ring), value, 'the latest is the last pushed')
      expect.equal(history.count(ring), #tail, 'the count is bounded by the capacity')
    end
  end
end)

test('a capacity that is not a positive integer raises', function()
  expect.raises(function()
    history.new(0)
  end, 'positive integer')
  expect.raises(function()
    history.new(1.5)
  end, 'positive integer')
end)

return test
