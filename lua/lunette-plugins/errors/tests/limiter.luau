local testing = require '@testing'
local expect = testing.expect
local limiter = require '@lunette-plugins/errors/limiter'

local test = testing.suite()

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
