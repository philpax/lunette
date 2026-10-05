local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/surfaces'
local plugin = require '@lunette-plugin'

local test = testing.suite()

test('inspection preserves offer ownership without evaluating offers and snapshots outlive disposal', function()
  local session = testing.start { 'surfaces' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local calls = 0
  local effect = service:offer(owner, {
    name = 'fixture.offer',
    list = function()
      calls += 1
      error 'inspection executed the offer'
    end,
  })
  local snapshot = service:inspect()
  expect.equal(snapshot.logicalRegistrationCount, 1, 'the logical registration count')
  expect.equal(snapshot.registrations[1].owner, owner, 'the owner identity')
  expect.equal(snapshot.registrations[1].source, 'surfaces.offer', 'the acquisition source')
  expect.equal(snapshot.registrations[1].name, 'fixture.offer', 'the supplied name')
  expect.equal(calls, 0, 'the callback count')
  expect.equal(
    pcall(function()
      snapshot.registrations[1].name = 'changed'
    end),
    false,
    'the immutable record'
  )
  expect.equal(
    pcall(function()
      snapshot.registrations[1].details.changed = true
    end),
    false,
    'the immutable details'
  )
  expect.equal(
    pcall(function()
      snapshot.registrations[1] = nil
    end),
    false,
    'the immutable list'
  )
  effect:dispose()
  effect:dispose()
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the count after disposal')
  expect.equal(snapshot.registrations[1].live, true, 'the detached earlier snapshot')
  expect.equal(calls, 0, 'inspection never evaluates the offer')
  session:close()
end)

test('inspection contains only current activation registrations after owner and provider outages', function()
  local session = testing.start { 'surfaces' }
  local observer = session:observe(contract.capability)
  local current, owner
  local instance = session:use(plugin.define {
    name = 'inspection-consumer',
    requires = { surfaces = contract.capability },
    init = function(context)
      owner = context
      current = context:require(contract.capability)
      current:offer(context, {
        name = 'fixture.outage',
        list = function()
          error 'inspection evaluated an offer'
        end,
      })
    end,
  })
  local before = current:inspect()
  expect.equal(before.registrations[1].owner, owner, 'the initial owner')
  instance:disable()
  expect.equal(observer.service:inspect().logicalRegistrationCount, 0, 'the registry after the owner ends')
  instance:enable()
  expect.equal(current:inspect().logicalRegistrationCount, 1, 'the re-enabled owner registration')
  session.instances.surfaces:disable()
  expect.equal(instance:state(), 'inactive', 'the consumer outage')
  session.instances.surfaces:enable()
  expect.equal(instance:state(), 'active', 'the consumer resumption')
  expect.equal(current:inspect().logicalRegistrationCount, 1, 'one new activation registration')
  expect.equal(before.logicalRegistrationCount, 1, 'the detached old activation snapshot')
  session:close()
end)

return test
