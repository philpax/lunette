local testing = require '@testing'
local expect = testing.expect
local definition = require('@lunette-plugins/desktop/rules').definition

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
end)

return test
