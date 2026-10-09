local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/bindings'
local test = testing.suite()

test('inspection describes an acquired chord without invoking its handler', function()
  local session = testing.start { 'frame', 'bindings' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local effect = service:register(owner, {
    chord = { key = 'a', modifiers = { 'control' } },
    run = function()
      error 'inspection dispatched a binding'
    end,
  })
  local entry = service:inspect().registrations[1]
  expect.equal(entry.owner, owner, 'the binding owner')
  expect.equal(entry.details.key, 'a', 'the key')
  expect.equal(entry.details.modifiers, 'control', 'the modifier')
  effect:dispose()
  expect.equal(#service:inspect().registrations, 0, 'disposed bindings')
  session:close()
end)

return test
