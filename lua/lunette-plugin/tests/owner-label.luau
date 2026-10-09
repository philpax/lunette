local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local test = testing.suite()

test('owner labels name the registered definition after the owner unloads', function()
  testing.native()
  local session = testing.start {}
  local held
  local instance = session:use(plugin.define {
    name = 'diagnostic-consumer',
    init = function(context)
      held = context
    end,
  })
  expect.equal(plugin.ownerLabel(held), 'diagnostic-consumer', 'the registered definition name')
  instance:disable()
  expect.equal(
    plugin.ownerLabel(held),
    'diagnostic-consumer',
    'retained diagnostics remain readable after owner unload'
  )
  session:close()
end)

return test
