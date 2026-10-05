local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local test = testing.suite()

test('owner labels identify registrations without invoking owner methods or metamethods', function()
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
  local forged = setmetatable({}, {
    __index = function()
      error 'owner lookup invoked a getter'
    end,
    __tostring = function()
      error 'owner lookup invoked tostring'
    end,
  })
  expect.equal(plugin.ownerLabel(forged), 'unregistered owner', 'unknown owners do not execute callbacks')
  instance:disable()
  expect.equal(
    plugin.ownerLabel(held),
    'diagnostic-consumer',
    'retained diagnostics remain readable after owner unload'
  )
  session:close()
end)

return test
