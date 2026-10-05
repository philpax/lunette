local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/placement'
local panels = require '@lunette-contracts/panels'
local test = testing.suite()

test('placement inspection preserves release ownership separately from the panel provider owner', function()
  local native = testing.native()
  local session = testing.start { 'panels', 'tags', 'rules', 'placement' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local target, _, effect = service:place(owner, { window = native.newWindow(23), properties = {} })
  local snapshot = service:inspect()
  expect.equal(snapshot.logicalRegistrationCount, 1, 'the placement registration')
  expect.equal(snapshot.registrations[1].owner, owner, 'the caller release owner')
  local panelOwner = session:observe(panels.capability).service:inspect().registrations[1].owner
  expect.equal(panelOwner == owner, false, 'the downstream panel is provider-owned')
  local listener = service:onPlaced(owner, {
    run = function()
      error 'inspection announced a placement'
    end,
  })
  expect.equal(service:inspect().logicalRegistrationCount, 2, 'the placement and listener')
  listener:dispose()
  effect:dispose()
  expect.equal(target.dead, true, 'the panel cleanup')
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the released placement')
  session:close()
end)

return test
