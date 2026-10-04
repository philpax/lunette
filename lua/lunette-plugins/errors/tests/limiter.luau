local testing = require '@testing'
local expect = testing.expect
local limiter = require '@lunette-plugins/errors/limiter'
local format = require '@lunette-plugins/errors/format'

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
  expect.equal(limit:suppressedCount 'same', 0, 'the forgotten key')
end)

test('a report is keyed by message and traceback, and its lines are bounded', function()
  expect.equal(format.key { message = 'm', traceback = 't' }, 'm\nt', 'the key')
  local lines = format.lines({ latest = 'a b c d e f', count = 2 }, { columns = 3, lines = 2 })
  expect.truthy(lines[1]:find('(2 so far)', 1, true), 'the count leads: ' .. lines[1])
  expect.equal(#lines, 3, 'the lines')
  expect.equal(lines[3], '…', 'the truncation mark')
end)

return test
