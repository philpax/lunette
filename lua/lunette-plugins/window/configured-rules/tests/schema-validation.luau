local testing = require '@testing'
local expect = testing.expect
local definition = require('../').definition
local checks = require '@lunette-contracts/schemas/rules'

local test = testing.suite()

test('the desktop config rejects a malformed rule and accepts a callback predicate and a matrix pose', function()
  expect.raises(function()
    definition.resolve { rules = { { match = { where = 42 } } } }
  end, 'match field where')
  local predicate = function(): boolean
    return true
  end
  local pose = lovr.math.newMat4()
  local settings = definition.resolve {
    rules = { { match = { where = predicate }, properties = { pose = pose } } },
  }
  expect.equal(settings.rules[1].match.where, predicate, 'the callback predicate')
  expect.equal(settings.rules[1].properties.pose, pose, 'the matrix pose')
  local extension = function() end
  local properties = checks.checkProperties { width = predicate, callback = extension, tags = { 'work' } }
  expect.equal(properties.width, predicate, 'a named property accepts an evaluator')
  expect.equal(properties.callback, extension, 'an extension function remains a literal')
  expect.truthy(table.isfrozen(checks.propertyKinds), 'shared property classifications are immutable')
end)

return test
