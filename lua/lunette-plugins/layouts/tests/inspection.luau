local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/layouts'
local test = testing.suite()

test('inspection reports layouts and listeners without applying or notifying', function()
  local session = testing.start { 'layouts' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local effect = service:register(owner, {
    name = 'fixture.layout',
    continuous = true,
    apply = function()
      error 'inspection applied a layout'
    end,
  })
  local listener = service:onChanged(owner, {
    run = function()
      error 'inspection notified a listener'
    end,
  })
  local snapshot = service:inspect()
  expect.equal(snapshot.logicalRegistrationCount, 2, 'the layout and listener')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(entry.owner, owner, 'the actual registering owner')
    if entry.kind == 'layout' then
      expect.equal(entry.details.continuous, true, 'the continuous flag')
    end
  end
  listener:dispose()
  effect:dispose()
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the disposed registrations')
  session:close()
end)

return test
