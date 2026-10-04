local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardModule = require '@lunette-plugins/keyboard'
local keyboardContract = require '@lunette-contracts/keyboard'
local surfacesContract = require '@lunette-contracts/surfaces'

local test = testing.suite()

local function start(config)
  local env = { drawnBy = {} }
  local tracing = keyboardModule.define {
    drawKey = function(pass, key, state, base)
      env.drawnBy[state.keyboard] = (env.drawnBy[state.keyboard] or 0) + 1
      base(pass, key, state)
    end,
  }
  env.session = testing.boot {
    'frame',
    'surfaces',
    'focus',
    { id = 'keyboard', definition = tracing },
    { id = 'desktop/keyboard', definition = require '@lunette-plugins/desktop/keyboard', config = config },
  }
  env.surfaces = env.session:observe(surfacesContract.capability)
  return env
end

local function wristOf(env)
  for _, candidate in ipairs(env.surfaces.service:all()) do
    if candidate.grabbable == false and candidate.onPress then
      return candidate
    end
  end
  return nil
end

test('the wrist button takes the configured size', function()
  local env = start { size = 0.2 }
  local wrist = wristOf(env)
  expect.truthy(wrist, 'the wrist button')
  expect.equal(wrist.width, 0.2, 'the width of the button')
  expect.equal(wrist.height, 0.2, 'the height of the button')
  env.session:close()
end)

test('a press shows the wrist keyboard and pulses the pressing pointer with the configured haptic', function()
  local env = start { haptic = { strength = 0.4 } }
  local pulses = {}
  local pointer = {
    vibrate = function(_self, haptic)
      pulses[#pulses + 1] = haptic
      return true
    end,
  }
  local wrist = wristOf(env)
  wrist:onPress(nil, nil, pointer)
  expect.equal(#pulses, 1, 'the pulses of the pressing pointer')
  expect.equal(pulses[1].strength, 0.4, 'the configured strength')
  expect.equal(pulses[1].duration, 0.05, 'the default duration')

  local shown
  for _, candidate in ipairs(env.surfaces.service:all()) do
    if candidate.setLayer then
      shown = candidate
    end
  end
  expect.truthy(shown and shown.visible, 'the wrist keyboard is offered once shown')
  env.session:close()
end)

test("the consumer draws its own keyboard and not another owner's", function()
  local env = start {}
  local other
  env.session:use(plugin.define {
    name = 'other-keyboard',
    requires = { keyboard = keyboardContract.capability },
    init = function(context)
      other = context:require(keyboardContract.capability):new(context)
    end,
  })
  expect.truthy(other.visible, "another owner's keyboard is visible")
  local wrist = wristOf(env)
  wrist:onPress(nil, nil, {
    vibrate = function()
      return true
    end,
  })
  local shown
  for _, candidate in ipairs(env.surfaces.service:all()) do
    if candidate ~= other and candidate.setLayer then
      shown = candidate
    end
  end
  env.session:update()
  env.session:draw()
  expect.truthy((env.drawnBy[shown] or 0) > 0, 'the wrist keyboard is drawn')
  expect.equal(env.drawnBy[other], nil, "another owner's keyboard drawn by the consumer")
  env.session:close()
end)

test('a hand the consumer does not know fails its activation by name', function()
  local env = start { hand = 'middle' }
  local diagnostic = tostring(env.session.instances['desktop/keyboard']:diagnostic())
  expect.truthy(
    diagnostic:find('plugin desktop/keyboard: option hand is left or right, not middle', 1, true),
    'the diagnostic: ' .. diagnostic
  )
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the failures reported')
  env.session:close()
end)

return test
