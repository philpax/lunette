local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/pacing'
local module = require '@lunette-plugins/pacing'
local test = testing.suite()

test('inspection labels unowned pacers without guessing their callers or evaluating policy', function()
  local session = testing.start {
    {
      id = 'pacing',
      definition = module.definition,
      config = {
        choose = function()
          error 'inspection chose pacing'
        end,
      },
    },
  }
  local service = session:observe(contract.capability).service
  local before = service:inspect()
  service:newPacer()
  local after = service:inspect()
  expect.equal(before.state.createdPacers, 0, 'the detached creation count')
  expect.equal(after.state.createdPacers, 1, 'the creation count')
  expect.equal(#after.registrations, 0, 'unowned objects are not owner registrations')
  expect.truthy(#after.unobservable > 0, 'the attribution limitation')
  session:close()
end)

return test
