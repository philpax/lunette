local testing = require '@testing'
local expect = testing.expect
local laser = require '@lunette-plugins/laser'
local interaction = require '@lunette-plugins/interaction'
local contract = require '@lunette-contracts/laser'
local pointing = require '@lunette-plugins/desktop/pointing/config'

local test = testing.suite()

test('parsed partial pointing overrides merge over configured laser and interaction provider defaults', function()
  testing.native()
  local session = testing.start {
    'drops',
    'focus',
    {
      id = 'interaction',
      definition = interaction.define { tuning = { reach = 12, reachMaximum = 9, scrollScale = 400 } },
    },
    {
      id = 'laser',
      definition = laser.define { style = { length = 4, cursorRadius = 0.02, hapticDuration = 0.04 } },
    },
  }
  local observed = session:observe(contract.capability)
  local colorOnly = pointing.schema.parse { laser = { style = { color = { 1, 0, 0, 1 } } } }
  local reachOnly = pointing.schema.parse { laser = { tuning = { reach = 3 } } }
  local colored = observed.service:new(observed.context, 'left', colorOnly.laser)
  local shorter = observed.service:new(observed.context, 'right', reachOnly.laser)
  expect.equal(colored.style.color[1], 1, 'color override')
  expect.equal(colored.style.color[2], 0, 'color override replaces green')
  expect.equal(colored.style.length, 4, 'configured laser length')
  expect.equal(colored.style.cursorRadius, 0.02, 'configured laser radius')
  expect.equal(colored.style.hapticDuration, 0.04, 'configured laser duration')
  expect.equal(colored.pointer.tuning.reach, 12, 'configured pointer reach')
  expect.equal(shorter.pointer.tuning.reach, 3, 'reach override')
  expect.equal(shorter.pointer.tuning.reachMaximum, 9, 'configured pointer sibling')
  expect.equal(shorter.pointer.tuning.scrollScale, 400, 'configured scroll scale')
  expect.equal(shorter.style.length, 4, 'unchanged configured style')
  local zero = observed.service:new(observed.context, 'left', {
    style = { hapticStrength = 0, hapticDuration = 0 },
    tuning = { scrollScale = 0 },
  })
  expect.equal(zero.style.hapticStrength, 0, 'zero strength is an override')
  expect.equal(zero.style.hapticDuration, 0, 'zero duration is an override')
  expect.equal(zero.pointer.tuning.scrollScale, 0, 'zero scale is an override')
  session:close()
end)

return test
