local testing = require '@testing'
local managerConfig = require '../config'
local expect = testing.expect
local test = testing.suite()

test('configuration takes metric sizes and rejects the removed canvas option', function()
  local defaults = managerConfig.schema.parse {}
  expect.equal(defaults.view, 'entries', 'the entry list is the default view')
  expect.equal(defaults.width, 1.1)
  expect.raises(function(): ()
    managerConfig.schema.parse({ width = 0.3 }, 'manager')
  end)
  expect.raises(function(): ()
    managerConfig.schema.parse({ pixels = 1280 }, 'manager')
  end)
end)

return test
