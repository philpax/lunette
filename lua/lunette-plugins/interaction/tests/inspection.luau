local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/interaction'
local test = testing.suite()

test('inspection describes pointers from private state without haptics or updates', function()
  testing.native()
  local session = testing.start { 'drops', 'focus', 'interaction' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local pointer = service:newPointer(owner, {
    vibrate = function()
      error 'inspection vibrated'
    end,
  })
  local snapshot = service:inspect()
  expect.equal(snapshot.logicalRegistrationCount, 1, 'the pointer registration')
  expect.equal(snapshot.registrations[1].owner, owner, 'the pointer owner')
  expect.equal(snapshot.registrations[1].details.pressedButtons, 0, 'the private input state')
  pointer:destroy()
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the destroyed pointer')
  session:close()
end)

return test
