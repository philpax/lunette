local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardModule = require '@lunette-plugins/keyboard'
local keyboardContract = require '@lunette-contracts/keyboard'
local surfacesContract = require '@lunette-contracts/surfaces'
local interactionContract = require '@lunette-contracts/interaction'

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
    'drops',
    'interaction',
    { id = 'keyboard', definition = tracing },
    { id = 'desktop/keyboard', definition = require '@lunette-plugins/desktop/keyboard', config = config },
  }
  env.surfaces = env.session:observe(surfacesContract.capability)
  return env
end

local function wristOf(env)
  for _, candidate in ipairs(env.surfaces.service:all()) do
    if candidate.grabbable == false and candidate.onPointer then
      return candidate
    end
  end
  return nil
end

local function press(wrist, pointer)
  wrist:onPointer {
    kind = 'press',
    pointer = pointer,
    button = 'left',
    x = 0.5,
    y = 0.5,
    captured = true,
    inside = true,
  }
end

local function shownKeyboard(env)
  for _, candidate in ipairs(env.surfaces.service:all()) do
    if candidate.setLayer then
      return candidate
    end
  end
  return nil
end

local function realPointer(env)
  local observed = env.session:observe(interactionContract.capability)
  return observed.service:newPointer(observed.context, {
    vibrate = function(haptic)
      return lovr.headset.vibrate('hand/right', haptic.strength, haptic.duration)
    end,
  })
end

local function drive(env, pointer, wrist, buttons)
  pointer:update({
    origin = vector.pack(wrist.pose:mul(0, 0, 1, 1)),
    direction = vector.pack(wrist.pose:mul(0, 0, -1, 0)),
    pose = lovr.math.newMat4(),
    buttons = buttons or {},
    grip = false,
    dt = 0.016,
  }, env.surfaces.service:all())
end

test('a real secondary press does not toggle or pulse the wrist keyboard', function()
  local env = start { haptic = { strength = 0.4 } }
  local wrist, pointer = wristOf(env), realPointer(env)
  drive(env, pointer, wrist, { right = true })
  drive(env, pointer, wrist)
  expect.equal(shownKeyboard(env), nil, 'secondary press does not show a keyboard')
  expect.equal(env.session.native.events.haptics or 0, 0, 'secondary press does not pulse')
  drive(env, pointer, wrist, { left = true })
  local shown = shownKeyboard(env)
  expect.truthy(shown and shown.visible, 'a primary press shows the keyboard')
  expect.equal(env.session.native.events.haptics, 1, 'one primary event produces one pulse')
  drive(env, pointer, wrist, { left = true, right = true })
  drive(env, pointer, wrist, { left = true })
  drive(env, pointer, wrist)
  expect.truthy(shown.visible, 'secondary and release events do not toggle again')
  expect.equal(env.session.native.events.haptics, 1, 'non-primary events do not duplicate the pulse')
  env.session:close()
end)

test('wrist tracking omission cancels a held real press without toggling on reacquisition', function()
  local env = start {}
  local wrist, pointer = wristOf(env), realPointer(env)
  local onPointer = wrist.onPointer
  local cancelled = {}
  wrist.onPointer = function(self, event)
    if event.kind == 'cancel' then
      cancelled[#cancelled + 1] = event
    end
    return onPointer(self, event)
  end
  drive(env, pointer, wrist, { left = true })
  local shown = shownKeyboard(env)
  local tracked = true
  lovr.headset.isTracked = function()
    return tracked
  end
  tracked = false
  drive(env, pointer, wrist, { left = true })
  expect.equal(#cancelled, 1, 'the next drive cancels the withdrawn wrist capture')
  expect.equal(cancelled[1].reason, 'surface-withdrawn', 'offer omission supplies the cancellation reason')
  expect.truthy(shown.visible, 'cancellation does not toggle the visible keyboard')
  tracked = true
  drive(env, pointer, wrist, { left = true })
  expect.truthy(shown.visible, 'held reacquisition cannot toggle')
  drive(env, pointer, wrist)
  expect.truthy(shown.visible, 'the quarantined release does not toggle')
  drive(env, pointer, wrist, { left = true })
  expect.equal(shown.visible, false, 'a fresh primary press toggles after the observed release')
  env.session:close()
end)

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
  press(wrist, pointer)
  expect.equal(#pulses, 1, 'the pulses of the pressing pointer')
  expect.equal(pulses[1].strength, 0.4, 'the configured strength')
  expect.equal(pulses[1].duration, 0.05, 'the default duration')
  local shown = shownKeyboard(env)
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
    press(wrist, pointer)
    local shown = shownKeyboard(env)
    expect.truthy(shown and shown.visible, 'the keyboard is visible')
    local hx, hy, hz = lovr.headset.getPosition 'head'
    local x, y, z = shown.pose:getPosition()
    expect.near(x, hx + 0.48, 1e-5, 'the horizontal x offset')
    expect.near(y, hy - 0.25, 1e-5, 'the vertical drop')
    expect.near(z, hz - 0.64, 1e-5, 'the horizontal z offset')
    press(wrist, pointer)
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
    press(wrist, pointer)
    local shown = shownKeyboard(env)
    local hx, hy, hz = lovr.headset.getPosition 'head'
    local x, y, z = shown.pose:getPosition()
    expect.near(x, hx, 1e-5, 'the fallback x position')
    expect.near(y, hy - 0.25, 1e-5, 'the vertical drop')
    expect.near(z, hz - 0.8, 1e-5, 'the fallback horizontal distance')
    press(wrist, pointer)
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
  press(wrist, {
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
