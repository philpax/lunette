local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/drops'
local test = testing.suite()

test('inspection shows drop listeners without notification delivery', function()
  local session = testing.start { 'drops' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local effect = service:onDropped(owner, {
    run = function()
      error 'inspection delivered a drop'
    end,
  })
  local snapshot = service:inspect()
  expect.equal(snapshot.logicalRegistrationCount, 1, 'the listener count')
  expect.equal(snapshot.registrations[1].owner, owner, 'the listener owner')
  effect:dispose()
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the disposed listener')
  session:close()
end)

return test
