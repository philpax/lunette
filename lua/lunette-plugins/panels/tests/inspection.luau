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

test('panel inspection reports owners, dead sources, and visibility overrides', function()
  local native = testing.native()
  local session = testing.start {
    { id = 'theme', definition = require('@lunette-plugins/theme').definition },
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = { rendering = 'layer' } },
  }
  local first, second = session:observe(contract.capability), session:observe(contract.capability)
  local service, owner = first.service, first.context
  local source = native.newWindow(21)
  local target = service:fromWindow(owner, source, {})
  local shown = service:inspect()
  expect.equal(count(shown, 'panel'), 1, 'the panel registration')
  expect.equal(shown.state.layerClaims, 1, 'the native claim state')
  expect.equal(shown.registrations[1].owner, owner, 'the panel owner')
  source.dead = true
  local entry = service:inspect().registrations[1]
  expect.equal(entry.live, false, 'a dead source makes the registration unavailable')
  expect.equal(entry.details.sourceDead, true, 'the inspected source state')

  local hidden = target:setHidden(second.context, { hidden = true })
  local snapshot = service:inspect()
  expect.equal(count(snapshot, 'visibility'), 1, 'one logical override')
  expect.equal(snapshot.state.layerClaims, 0, 'hiding releases the native claim')
  hidden:dispose()
  target:destroy(owner)
  expect.equal(#service:inspect().registrations, 0, 'the released registrations')
  session:close()
end)

return test
