local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/rules'
local test = testing.suite()

test('inspection reports source ownership and precedence without resolution', function()
  local session = testing.start { 'rules' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local effect = service:addSource(owner, {
    name = 'fixture.rules',
    precedence = 17,
    resolve = function()
      error 'inspection resolved rules'
    end,
  })
  local entry = service:inspect().registrations[1]
  expect.equal(entry.owner, owner, 'the source owner')
  expect.equal(entry.name, 'fixture.rules', 'the supplied source name')
  expect.equal(entry.details.precedence, 17, 'the source precedence')
  effect:dispose()
  expect.equal(#service:inspect().registrations, 0, 'the disposed source')
  session:close()
end)

return test
