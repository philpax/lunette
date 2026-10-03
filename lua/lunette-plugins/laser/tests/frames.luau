-- Covers what a laser does each frame: reading input through its reader or the provider's readInput hook and
-- button mapping, hovering a surface with a haptic pulse, and drawing through the draw hook.
local testing = require '@testing'
local expect = testing.expect
local laserContract = require '@lunette-contracts/laser'
local laser = require '@lunette-plugins/laser'

local test = testing.suite()

-- The laser provider, `definition` or the built-in one, and the providers it needs over the fake native API,
-- with a consumer whose context is `owner`.
local function start(definition)
  local env = { native = testing.native() }
  env.session = testing.start {
    'drops',
    'focus',
    'interaction',
    { id = 'laser', definition = definition or laser.definition },
  }
  local consumer = env.session:observe(laserContract.capability)
  env.service, env.owner = consumer.service, consumer.context
  return env
end

-- The draw calls named `name` the fake's pass has received.
local function calls(env, name)
  local found = {}
  for _, call in ipairs(env.native.events.draw) do
    if call[1] == name then
      found[#found + 1] = call
    end
  end
  return found
end

local function frame(x, y, z)
  return {
    pose = lovr.math.newMat4(),
    origin = vector.create(0, 0, 0),
    direction = vector.create(x, y, z),
    buttons = {},
    grip = false,
    dt = 1 / 60,
  }
end

test("each laser reads its own input, and a hover pulses that hand's controller and draws a cursor", function()
  local env = start()
  local inputs = { left = frame(0, 0, -1), right = frame(0, 1, 0) }
  local reads = { left = 0, right = 0 }
  local function readInput(hand)
    reads[hand] += 1
    return inputs[hand]
  end
  env.service:attach(env.owner, { readInput = readInput })
  local style = env.service.STYLE

  env.service:update {}
  expect.truthy(reads.left == 1 and reads.right == 1, 'each hand read once')
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'line'), 2, 'a beam per hand')
  expect.equal(#calls(env, 'sphere'), 0, 'no cursor without a hover')

  -- The surface is hit only by a beam pointing forward, so the left hand hovers it and the right does not.
  local hovers = 0
  local surface = {
    dead = false,
    raycast = function(_, _, direction)
      if direction.y > 0.5 then
        return nil
      end
      return 1, 2, 3
    end,
    onHover = function()
      hovers += 1
    end,
  }
  env.service:update { surface }
  expect.equal(hovers, 1, 'the hovered surface')
  expect.equal(env.native.events.haptics, 1, 'one pulse')
  local haptic = env.native.events.haptic
  expect.equal(haptic.device, 'hand/left', "the pulse reaches the hovering hand's controller")
  expect.equal(haptic.strength, style.hapticStrength, 'the pulse strength')
  expect.equal(haptic.duration, style.hapticDuration, 'the pulse duration')

  table.clear(env.native.events.draw)
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'line'), 2, 'a beam per hand')
  expect.equal(#calls(env, 'sphere'), 1, 'a cursor for the hovering hand')
  local colors = calls(env, 'setColor')
  for index, value in ipairs(style.hoverColor) do
    expect.equal(colors[1][index + 1], value, 'the hovering beam colour ' .. index)
  end
  for index = 2, 5 do
    expect.equal(colors[#colors][index], 1, 'the colour is reset to white ' .. (index - 1))
  end

  inputs.left = nil
  env.service:update {}
  expect.truthy(reads.left == 3 and reads.right == 3, 'each hand read every update')
  expect.equal(env.native.events.haptics, 1, 'a lost hand does not pulse')
  env.session:close()
end)

test('the readInput and draw hooks wrap the defaults for every laser, and buttons map the controller', function()
  local read, drawn = {}, {}
  local hooked = laser.define {
    name = 'hooked-laser',
    buttons = { { control = 'trigger', button = 'right' }, { control = 'b', button = 'middle' } },
    readInput = function(hand, base)
      local result = base(hand)
      read[#read + 1] = { hand = hand, frame = result }
      return result
    end,
    draw = function(target, pass, base)
      drawn[#drawn + 1] = target.hand
      if target.hand == 'left' then
        base(target, pass)
      end
    end,
  }
  local env = start(hooked)
  env.native.events.trigger = true
  env.service:attach(env.owner)

  env.service:update {}
  expect.truthy(#read == 2 and read[1].hand == 'left' and read[2].hand == 'right', 'the hook saw each hand')
  local buttons = read[1].frame.buttons
  expect.equal(buttons.right, true, 'the trigger presses the mapped button')
  expect.equal(buttons.left, nil, 'the mapping replaces the default wholesale')
  expect.equal(buttons.middle, nil, 'b is up')
  expect.equal(read[1].frame.grip, false, 'the grip')

  local pass = env.native.events.pass
  env.service:draw(pass)
  expect.truthy(#drawn == 2 and drawn[1] == 'left' and drawn[2] == 'right', 'the bulk draw honours the hook')
  expect.equal(#calls(env, 'line'), 1, 'only the hand whose hook called the default drew a beam')
  env.service:forHand('right'):draw(pass)
  expect.truthy(#drawn == 3 and #calls(env, 'line') == 1, "a laser's own draw is the hook too")

  -- A laser's own reader replaces the hook for that laser, and its style merges over the provider's.
  local own = 0
  env.service:forHand('left'):destroy()
  local left = env.service:new(env.owner, 'left', {
    readInput = function()
      own += 1
      return nil
    end,
    style = { length = 9 },
  })
  env.service:update {}
  expect.equal(own, 1, 'the own reader')
  expect.truthy(#read == 3 and read[3].hand == 'right', 'the hook read only the other hand')
  expect.equal(left.style.length, 9, 'the given style')
  expect.equal(left.style.cursorRadius, env.service.STYLE.cursorRadius, 'the merged style')
  env.session:close()

  expect.raises(function()
    laser.define { buttons = { { control = 'pinch', button = 'left' } } }
  end, 'controller button', 'a mapping is checked where it is written')
end)

test('the default reader maps the trigger to the left button', function()
  local env = start()
  env.native.events.trigger = true
  env.service:attach(env.owner)
  env.service:update {}
  local input = env.service:forHand('left').input
  expect.truthy(input and input.buttons.left == true and input.buttons.right == nil, 'the default mapping')
  env.session:close()
end)

return test
