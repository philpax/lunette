local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/errors'
local module = require '@lunette-plugins/errors'
local test = testing.suite()

test('inspection reads subscriber and history state without sampling the clock or clearing reports', function()
  testing.native()
  local session = testing.start {
    {
      id = 'errors',
      definition = module.definition,
      config = {
        clock = function()
          error 'inspection sampled the clock'
        end,
      },
    },
  }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local effect = service:subscribe(owner, {
    run = function()
      error 'inspection delivered a report'
    end,
    cleared = function()
      error 'inspection cleared reports'
    end,
  })
  local snapshot = service:inspect()
  expect.equal(#snapshot.registrations, 2, 'the subscriber and native listener registrations')
  expect.equal(snapshot.registrations[1].owner, owner, 'the subscriber owner')
  expect.equal(snapshot.state.history, 0, 'the history size')
  effect:dispose()
  expect.equal(#service:inspect().registrations, 1, 'only the provider listener remains')
  session:close()
end)

return test
