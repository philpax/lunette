local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local interactionContract = require '@lunette-contracts/interaction'
local focusContract = require '@lunette-contracts/focus'
local interaction = require '@lunette-plugins/interaction'

local test = testing.suite()

local function translation(x, y, z)
  return lovr.math.newMat4():translate(x or 0, y or 0, z or 0)
end

local function start(definition)
  local env = { native = testing.native(), pressed = {}, released = {}, leaves = 0 }
  env.session = testing.start {
    'drops',
    'focus',
    { id = 'interaction', definition = definition or interaction.definition },
  }
  env.consumer = env.session:use(plugin.define {
    name = 'interaction-test',
    requires = { interaction = interactionContract.capability, focus = focusContract.capability },
    init = function(context)
      env.owner = context
      env.interaction = context:require(interactionContract.capability)
      env.focus = context:require(focusContract.capability)
    end,
  })
  local seat = { id = 1, dead = false }
  function seat:setFocus(sink)
    self.focus = sink
    return true
  end
  env.seat = seat
  require('@lunette').defaultSeat = function()
    return seat
  end
  local sink = { domain = 'window', id = 1, dead = false }
  function sink:button(button, isDown, actualSeat)
    expect.equal(actualSeat, seat, 'the seat a button arrives from')
    local list = if isDown then env.pressed else env.released
    list[#list + 1] = button
  end
  function sink:leave()
    env.leaves += 1
  end
  function sink:pointer() end
  function sink:scroll() end
  env.sink = sink
  return env
end

local function surface(env, z)
  local result = { dead = false, pose = translation(0, 0, z), width = 1, height = 1 }
  function result:setHighlighted(value)
    self.highlighted = value
  end
  function result:setPose(value)
    self.pose:set(value)
  end
  function result:setSize(width)
    self.width = width
  end
  function result:sink()
    return env.sink
  end
  function result:raycast()
    return 10, 20, 1
  end
  return result
end

local function input(fields)
  return {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = fields.pose or translation(),
    buttons = fields.buttons or {},
    grip = fields.grip or false,
    dt = 0.016,
  }
end

test('a pointer is made only for a context requiring interaction, and destroys once', function()
  local env = start()
  env.session:use(plugin.define {
    name = 'stranger',
    init = function(context)
      expect.raises(function()
        env.interaction:newPointer(context)
      end, nil, 'a pointer for a context that does not require interaction')
    end,
  })
  expect.equal(#env.interaction:pointers(), 0, 'the pointers after the refusal')
  local pointer = env.interaction:newPointer(env.owner)
  expect.truthy(pointer:destroy(), 'the first destroy')
  expect.falsy(pointer:destroy(), 'a second destroy answers false')
  env.session:close()
end)

test("a pointer's own tuning merges over the provider's", function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  expect.equal(pointer.seat, env.seat, 'the seat')
  expect.equal(pointer.tuning.reach, env.interaction.TUNING.reach, 'the default reach')
  local near = env.interaction:newPointer(env.owner, { tuning = { reach = 1 } })
  expect.equal(near.tuning.reach, 1, 'the merged reach')
  expect.equal(near.tuning.scrollScale, env.interaction.TUNING.scrollScale, 'the inherited scroll scale')
  env.session:close()
end)

test('a surface two pointers hover stays highlighted until both have left', function()
  local env = start()
  local first, second = env.interaction:newPointer(env.owner), env.interaction:newPointer(env.owner)
  local shared = surface(env)
  first:hover(shared)
  second:hover(shared)
  first:hover(nil)
  expect.truthy(shared.highlighted, 'another pointer still hovers the surface')
  second:hover(nil)
  expect.falsy(shared.highlighted, 'the last pointer to leave clears the highlight')
  first:hover(shared)
  expect.equal(first.hovered, shared, 'what the pointer hovers')
  env.session:close()
end)

test("a press presses its button and gives the seat's keyboard to the sink through focus", function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  local target = surface(env)
  pointer:setButton { pressed = true, sink = env.sink, surface = target }
  expect.equal(env.pressed[1], 'left', 'the default button')
  expect.equal(env.seat.focus, env.sink, 'the native focus')
  local focused = env.focus:focused()
  expect.truthy(focused and not focused.dead, 'the focused target')
  pointer:setButton { button = 'right', pressed = true, sink = env.sink, surface = target }
  pointer:setButton { button = 'right', pressed = false }
  expect.equal(env.pressed[2], 'right', 'a second button is its own press')
  expect.equal(env.released[1], 'right', 'and its own release')
  env.session:close()
end)

test('two pointers share a grab: pushing, dragging, scaling, and a partner letting go', function()
  local env = start()
  local first, second = env.interaction:newPointer(env.owner), env.interaction:newPointer(env.owner)
  local target = surface(env, -2)
  expect.truthy(first:beginGrab(target, translation()), 'the first grab')
  expect.equal(first.grabbed, target, 'what the first pointer carries')
  first:push { deflection = 1, dt = 1 }
  first:dragTo(translation(1))
  local x, _, z = target.pose:getPosition()
  expect.near(x, 1, 1e-5, 'the drag moves the surface with the hand')
  expect.truthy(z < -2, 'the push moves the surface along the ray')
  first:dragTo(translation())
  expect.near((target.pose:getPosition()), 0, 1e-5, 'the drag back')
  expect.truthy(second:beginGrab(target, translation(1)), 'the second grab of the same surface')
  second:scaleWith(translation(2))
  expect.near(target.width, 2, 1e-5, 'two hands moving apart scale the surface')
  expect.truthy(first:endGrab(), 'ending a grab answers that something was carried')
  expect.equal(first.grabbed, nil, 'the first pointer after letting go')
  second:scaleWith(translation(2))
  second:dragTo(translation(5))
  expect.near((target.pose:getPosition()), 3, 1e-5, 'the partner letting go turns a scale into a grab')
  expect.truthy(second:endGrab(), 'the second pointer lets go')
  env.session:close()
end)

test("an unloading owner's pointers release their buttons, leave, and take their focus back", function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  local target = surface(env, -2)
  pointer:hover(target)
  pointer:setButton { pressed = true, sink = env.sink, surface = target }
  local stale = env.owner
  env.consumer:disable()
  expect.equal(env.seat.focus, nil, 'a destroyed pointer withdraws the native focus it gave')
  expect.equal(env.focus:focused(), nil, 'a destroyed pointer is no longer focused')
  expect.truthy(pointer.dead, 'the pointer')
  expect.equal(env.released[1], 'left', 'the held button is released')
  expect.equal(env.leaves, 1, 'the sink is left')
  expect.falsy(target.highlighted, 'the highlight is cleared')
  expect.equal(#env.interaction:pointers(), 0, 'the pointers')
  expect.falsy(pointer:beginGrab(target, translation()), 'a dead pointer grabs nothing')
  pointer:setButton { pressed = true, sink = env.sink, surface = target }
  expect.equal(#env.pressed, 1, 'a dead pointer presses nothing')
  expect.raises(function()
    env.interaction:newPointer(stale)
  end, nil, 'a pointer for a stale owner')
  env.session:close()
end)

test('update maps input onto the pointer: buttons press, a grip grabs, and releasing it drops', function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  local plate = surface(env, -1)
  pointer:update(input { buttons = { left = true, middle = true } }, { plate })
  expect.equal(pointer.hovered, plate, 'the surface the ray hits')
  expect.equal(pointer.hitX, 10, 'the hit coordinate')
  expect.equal(pointer.distance, 1, 'the hit distance')
  expect.equal(table.concat(env.pressed, ' '), 'left middle', 'the buttons held')
  pointer:update(input {}, { plate })
  pointer:update(input { grip = true }, { plate })
  expect.equal(pointer.grabbed, plate, 'the grip grabs')
  pointer:update(input {}, { plate })
  expect.equal(pointer.grabbed, nil, 'releasing the grip drops the surface')
  env.session:close()
end)

test('a drive hook remaps input, a constrain hook places what is carried, and focusOnPress can be off', function()
  local remapped = 0
  local env = start(interaction.define {
    name = 'hooked-interaction',
    focusOnPress = false,
    drive = function(pointer, given, surfaces, base)
      remapped += 1
      base(pointer, {
        origin = given.origin,
        direction = given.direction,
        pose = given.pose,
        buttons = { right = given.buttons.left },
        grip = given.grip,
        dt = given.dt,
      }, surfaces)
    end,
    constrain = function(target, pose, base)
      local x, _, z = base(target, pose):getPosition()
      return translation(x, 1.5, z)
    end,
  })
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  local plate = surface(env, -1)
  pointer:update(input { buttons = { left = true } }, { plate })
  expect.equal(remapped, 1, 'the drive hook ran')
  expect.equal(table.concat(env.pressed, ' '), 'right', 'the drive hook remapped the trigger')
  expect.equal(env.seat.focus, nil, 'focusOnPress = false gives no native focus')
  expect.equal(env.focus:focused(), nil, 'focusOnPress = false gives no focus grant')
  pointer:update(input {}, { plate })
  pointer:update(input { grip = true }, { plate })
  expect.equal(pointer.grabbed, plate, 'the grip grabs')
  pointer:update(input { grip = true, pose = translation(2, 4) }, { plate })
  local x, y = plate.pose:getPosition()
  expect.near(x, 2, 1e-5, 'the constraint allows the slide')
  expect.near(y, 1.5, 1e-5, 'the constraint keeps the height')
  pointer:update(input {}, { plate })
  pointer:focus(env.sink)
  expect.equal(env.seat.focus, env.sink, 'explicit focus still gives native focus')
  expect.truthy(env.focus:focused(), 'explicit focus still gives a focus grant')
  env.session:close()
end)

test('a failing release raises to a direct destroy, and is reported against an owner that unloads', function()
  local env = start()
  local survivorOwner
  env.session:use(plugin.define {
    name = 'survivor',
    requires = { interaction = interactionContract.capability },
    init = function(context)
      survivorOwner = context
    end,
  })
  local failedReleases = 0
  local brokenSink = { domain = 'host', monitor = { id = 'release-fixture' }, dead = false }
  function brokenSink:button(_, isDown)
    if not isDown then
      failedReleases += 1
      error 'native button release failed'
    end
  end
  local broken = env.interaction:newPointer(env.owner)
  broken:setButton { pressed = true, sink = brokenSink }
  expect.raises(function()
    broken:destroy()
  end, 'native button release failed', 'a direct destroy')
  expect.equal(failedReleases, 1, 'the releases attempted')
  expect.falsy(broken:destroy(), 'the pointer ended despite the failure')
  expect.truthy(env.interaction:newPointer(survivorOwner), 'the provider still serves')

  local leaking = env.interaction:newPointer(env.owner)
  leaking:setButton { pressed = true, sink = brokenSink }
  env.consumer:disable()
  expect.equal(failedReleases, 2, 'the releases attempted')
  expect.truthy(leaking.dead, 'the pointer of the unloaded owner')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('native button release failed', 1, true), 'the reported failure')
  expect.equal(env.consumer:state(), 'quarantined', 'the failing owner')
  expect.equal(env.session.instances.interaction:state(), 'active', 'the provider')
  expect.truthy(env.interaction:newPointer(survivorOwner), 'the provider still serves after the unload')
  env.session:close()
end)

return test
