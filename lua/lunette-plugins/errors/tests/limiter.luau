local testing = require '@testing'
local expect = testing.expect
local limiter = require '@lunette-plugins/errors/limiter'

local test = testing.suite()

test('a repeat within the window is withheld, and the next one after it carries the count', function()
  local limit = limiter.new(5, 2)
  local first, suppressed = limit:record('same', 0)
  expect.truthy(first, 'the first occurrence is let through')
  expect.equal(suppressed, 0, 'nothing withheld before it')
  expect.falsy(limit:record('same', 1), 'a repeat within the window')
  local third, repeated = limit:record('same', 5)
  expect.truthy(third, 'a repeat after the window')
  expect.equal(repeated, 1, 'the repeats withheld')
end)

test('the limiter forgets the oldest key past its bound', function()
  local limit = limiter.new(5, 2)
  limit:record('same', 0)
  limit:record('same', 1)
  limit:record('one', 6)
  limit:record('two', 7)
  local delivered, suppressed = limit:record('same', 8)
  expect.truthy(delivered, 'the forgotten key is let through')
  expect.equal(suppressed, 0, 'the forgotten key carries no withheld count')
end)

return test
