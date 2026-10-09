local testing = require '@testing'
local expect = testing.expect
local config = require '@lunette-plugins/desktop/rules/config'
local definition = require '@lunette-plugins/desktop/rules'

local test = testing.suite()

test('the desktop config rejects a malformed rule and accepts a callback predicate and a matrix pose', function()
  local malformed = { rules = { { match = { where = 42 } } } }
  expect.raises(function()
    config.schema.parse(malformed)
  end, 'match field where', 'schema parse')
  expect.raises(function()
    definition.resolve(malformed)
  end, 'match field where', 'definition resolution')

  local predicate = function()
    return true
  end
  local pose = lovr.math.newMat4()
  local settings = definition.resolve {
    rules = { { match = { where = predicate }, properties = { pose = pose } } },
  }
  expect.equal(settings.rules[1].match.where, predicate, 'the callback predicate')
  expect.equal(settings.rules[1].properties.pose, pose, 'the matrix pose')
end)

return test
