local testing = require '@testing'
local expect = testing.expect
local errorLines = require '../lines'

local test = testing.suite()

test('the lines of a report lead with its count and are bounded', function()
  local lines = errorLines.of({ latest = 'a b c d e f', count = 2 }, { columns = 3, lines = 2 })
  expect.truthy(lines[1]:find('(2 so far)', 1, true), 'the count leads: ' .. lines[1])
  expect.equal(#lines, 3, 'the lines')
  expect.equal(lines[3], '…', 'the truncation mark')
end)

return test
