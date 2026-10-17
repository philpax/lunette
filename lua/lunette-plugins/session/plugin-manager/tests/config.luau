local testing = require '@testing'
local managerConfig = require '../config'
local expect = testing.expect
local test = testing.suite()

test('a width below the usable panel size is rejected', function()
  expect.raises(function(): ()
    managerConfig.schema.parse({ width = 0.3 }, 'manager')
  end)
end)

return test
