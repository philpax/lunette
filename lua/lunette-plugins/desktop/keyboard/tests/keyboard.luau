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

test('the wrist button takes the configured vector offset without changing it', function()
  local offset = vector.pack(0.2, -0.3, 0.4)
  local env = start { offset = offset }
  local wrist = wristOf(env)
  local x, y, z = lovr.headset.getPosition 'hand/left'
  local position = vector.pack(wrist.pose:getPosition())
  expect.near(position.x, x + offset.x, 1e-5, 'the wrist x offset')
  expect.near(position.y, y + offset.y, 1e-5, 'the wrist y offset')
  expect.near(position.z, z + offset.z, 1e-5, 'the wrist z offset')
  expect.equal(offset, vector.pack(0.2, -0.3, 0.4), 'the configured offset is unchanged')
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

test('a pitched head keeps the keyboard at the configured horizontal distance', function()
  local env = start { placement = { distance = 0.8, drop = 0.25 } }
  local wrist = wristOf(env)
  local pointer = {
    vibrate = function()
      return true
    end,
  }
  for _, pitch in ipairs { -math.pi / 3, 0, math.pi / 3 } do
    lovr.headset.getDirection = function()
      return math.cos(pitch) * 0.6, math.sin(pitch), -math.cos(pitch) * 0.8
    end
    wrist:onPress(nil, nil, pointer)
    local shown
    for _, candidate in ipairs(env.surfaces.service:all()) do
      if candidate.setLayer then
        shown = candidate
      end
    end
    expect.truthy(shown and shown.visible, 'the keyboard is visible')
    local hx, hy, hz = lovr.headset.getPosition 'head'
    local x, y, z = shown.pose:getPosition()
    expect.near(x, hx + 0.48, 1e-5, 'the horizontal x offset')
    expect.near(y, hy - 0.25, 1e-5, 'the vertical drop')
    expect.near(z, hz - 0.64, 1e-5, 'the horizontal z offset')
    wrist:onPress(nil, nil, pointer)
  end
  env.session:close()
end)

test('a near-vertical head direction places the keyboard along the forward fallback', function()
  local env = start { placement = { distance = 0.8, drop = 0.25 } }
  local wrist = wristOf(env)
  for _, direction in ipairs { vector.pack(0, 1, 0), vector.pack(0.0001, -1, 0.0001) } do
    lovr.headset.getDirection = function()
      return direction:unpack()
    end
    local pointer = {
      vibrate = function()
        return true
      end,
    }
    wrist:onPress(nil, nil, pointer)
    local shown
    for _, candidate in ipairs(env.surfaces.service:all()) do
      if candidate.setLayer then
        shown = candidate
      end
    end
    local hx, hy, hz = lovr.headset.getPosition 'head'
    local x, y, z = shown.pose:getPosition()
    expect.near(x, hx, 1e-5, 'the fallback x position')
    expect.near(y, hy - 0.25, 1e-5, 'the vertical drop')
    expect.near(z, hz - 0.8, 1e-5, 'the fallback horizontal distance')
    wrist:onPress(nil, nil, pointer)
  end
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
    diagnostic:find('plugin desktop/keyboard: option hand matches no alternative', 1, true),
    'the diagnostic: ' .. diagnostic
  )
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the failures reported')
  env.session:close()
end)

test('nested keyboard settings retain defaults and vectors remain native values', function()
  local descriptor = require('@lunette-plugins/desktop/keyboard/config').schema
  local offset = vector.pack(0.1, -0.2, 0.3)
  local settings = descriptor.parse { placement = { distance = 0.8 }, haptic = {}, offset = offset }
  expect.equal(settings.placement.distance, 0.8, 'the configured distance')
  expect.equal(settings.placement.drop, 0.35, 'the default drop')
  expect.equal(settings.haptic.strength, 0.3, 'the default haptic strength')
  expect.equal(settings.offset, offset, 'the vector offset')
  local changed = descriptor.resolve({ placement = { tilt = 0 } }, settings)
  expect.equal(changed.placement.distance, 0.8, 'the resolved distance retained as the base')
  expect.equal(changed.placement.tilt, 0, 'the configured tilt')
end)

return test
