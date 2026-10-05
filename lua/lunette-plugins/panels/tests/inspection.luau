local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/panels'
local test = testing.suite()

local function count(snapshot, kind)
  local total = 0
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind then
      total += 1
    end
  end
  return total
end

local function registration(snapshot, kind, sourceId)
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind and (sourceId == nil or entry.details.sourceId == sourceId) then
      return entry
    end
  end
  error('missing ' .. kind .. ' registration')
end

test('panel inspection separates logical ownership from layer resources and reused visibility effects', function()
  local native = testing.native()
  local session = testing.start { 'panels' }
  local first, second = session:observe(contract.capability), session:observe(contract.capability)
  local service, owner = first.service, first.context
  local source = native.newWindow(21)
  local target = service:fromWindow(owner, source, {})
  local claim = target.claim
  local shown = service:inspect()
  expect.equal(count(shown, 'panel'), 1, 'the panel registration')
  expect.equal(shown.state.layerClaims, 1, 'the native claim state')
  expect.equal(shown.registrations[1].owner, owner, 'the panel owner')
  source.dead = true
  local deadSource = service:inspect()
  local entry = registration(deadSource, 'panel', source.id)
  expect.equal(deadSource.logicalRegistrationCount, shown.logicalRegistrationCount, 'the retained logical entry')
  expect.equal(entry.live, false, 'a dead source makes the registration unavailable')
  expect.equal(entry.dead, true, 'the dead-source registration status')
  expect.equal(entry.details.sourceDead, true, 'the inspected source state')
  expect.equal(target.dead, false, 'inspection does not retire the panel')
  expect.equal(service:all()[1], target, 'inspection does not prune the panel')
  expect.equal(target.claim, claim, 'inspection keeps the claim attached')
  expect.equal(claim.dead, false, 'inspection does not release the claim')
  expect.equal(deadSource.state.layerClaims, 1, 'inspection does not change the native claim count')

  local hidden = target:setHidden(second.context, { hidden = true })
  expect.equal(target:setHidden(second.context, { hidden = true }), hidden, 'the reused visibility effect')
  local snapshot = service:inspect()
  expect.equal(count(snapshot, 'visibility'), 1, 'one logical override')
  expect.equal(snapshot.state.layerClaims, 0, 'hiding releases the native claim')
  expect.equal(shown.state.layerClaims, 1, 'the earlier state is detached')
  expect.equal(deadSource.state.layerClaims, 1, 'the dead-source state is detached')

  hidden:dispose()
  target:destroy(owner)
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the released registrations')
  session:close()
end)

return test
