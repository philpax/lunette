local testing = require '@testing'
local expect = testing.expect
local definition = require('@lunette-plugins/desktop/rules').definition
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
  expect.equal(#checks.checkRules {}, 0, 'an empty rules list')
  expect.equal(checks.propertyKinds.pose, 'pose', 'the shared property classification')
  expect.equal(checks.matchKinds.where, 'function', 'the shared match classification')
  expect.truthy(table.isfrozen(checks.propertyKinds), 'property classifications are immutable')
  expect.truthy(table.isfrozen(checks.matchKinds), 'match classifications are immutable')
  expect.raises(function()
    checks.checkRules { [2] = {} }
  end, 'rules:', 'a sparse rules list')
  expect.raises(function()
    checks.checkRules { extra = {} }
  end, 'is not one of its positions', 'a rules list rejects named positions')
  expect.raises(function()
    checks.checkMatch(setmetatable({}, {}))
  end, 'without a metatable', 'a match rejects a metatable')
  expect.raises(function()
    checks.checkRule({ unknown = true }, 'fixture rule')
  end, 'fixture rule has an unknown field', 'a rule preserves its validation label')
  expect.raises(function()
    checks.checkMatch { width = math.huge }
  end, 'match field width', 'a numeric match is finite')
  expect.raises(function()
    checks.checkProperties { width = 0 / 0 }
  end, 'property width', 'a numeric property is finite')
  expect.raises(function()
    checks.checkProperties { pose = {} }
  end, 'property pose', 'a pose is a matrix or layout name')
  expect.raises(function()
    checks.checkProperties { tags = { 'work', false } }
  end, 'string at position 2', 'tags name each entry with a string')
  expect.raises(function()
    checks.checkProperties { tags = { [2] = 'work' } }
  end, 'rules:', 'a sparse tag list')
end)

return test
