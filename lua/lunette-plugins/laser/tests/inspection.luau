local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/laser'
local test = testing.suite()

test('inspection separates lasers from their owned seats and attach does not duplicate registrations', function()
  testing.native()
  local session = testing.start { 'theme', 'drops', 'focus', 'interaction', 'laser' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local options = {
    readInput = function()
      error 'inspection sampled input'
    end,
  }
  local lasers = service:attach(owner, options)
  service:attach(owner, options)
  local snapshot = service:inspect()
  expect.equal(snapshot.logicalRegistrationCount, 2, 'one registration per hand')
  expect.equal(snapshot.state.ownedSeats, 2, 'the native seat resource count')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(entry.owner, owner, 'the laser owner')
  end
  for _, laser in ipairs(lasers) do
    laser:destroy()
  end
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the destroyed lasers')
  expect.equal(service:inspect().state.ownedSeats, 0, 'the released seats')
  session:close()
end)

return test
