local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/keyboard'
local test = testing.suite()

test('inspection reads board state without querying keyboard targets or legends', function()
  testing.native()
  local session = testing.start { 'theme', 'focus', 'keyboard' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local board = service:new(owner, {
    target = function()
      error 'inspection queried the target'
    end,
  })
  local snapshot = service:inspect()
  expect.equal(snapshot.logicalRegistrationCount, 1, 'the board registration')
  expect.equal(snapshot.registrations[1].owner, owner, 'the board owner')
  expect.equal(snapshot.registrations[1].details.visible, true, 'the captured visibility')
  board:setVisible(false)
  expect.equal(service:inspect().registrations[1].details.visible, false, 'the live visibility')
  expect.equal(snapshot.registrations[1].details.visible, true, 'the detached visibility')
  board:destroy()
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the destroyed board')
  session:close()
end)

return test
