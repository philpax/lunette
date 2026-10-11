local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local interactionContract = require '@lunette-contracts/interaction'
local focusContract = require '@lunette-contracts/focus'
local interaction = require '@lunette-plugins/interaction'

local test = testing.suite()

type Sink = {
  domain: 'window' | 'host',
  id: number?,
  monitor: { read id: string }?,
  dead: boolean,
  button: (Sink, string, boolean, Seat?) -> (),
  leave: ((Sink) -> ())?,
  pointer: ((Sink) -> ())?,
  scroll: ((Sink) -> ())?,
}
type Seat = { id: number, dead: boolean, calls: number, focus: Sink?, setFocus: (Seat, Sink?) -> boolean }
type Environment = {
  native: typeof(testing.native()),
  pressed: { string },
  released: { string },
  leaves: number,
  session: typeof(testing.start {})?,
  consumer: adapter.Instance<unknown>?,
  owner: adapter.Context?,
  interaction: interactionContract.Service?,
  focus: focusContract.Service?,
  seat: Seat?,
  defaultSeat: Seat?,
  sink: Sink?,
  newSeat: (number) -> Seat,
  window: (number) -> Sink,
  host: (string) -> Sink,
}
type Surface = {
  dead: boolean,
  pose: Mat4,
  width: number,
  height: number,
  highlighted: boolean?,
  setHighlighted: (Surface, boolean) -> (),
  setPose: (Surface, Mat4) -> (),
  setSize: (Surface, number) -> (),
  sink: (Surface) -> Sink,
  raycast: (Surface) -> (number, number, number),
}
type InputFields = { read pose: Mat4?, read buttons: { [string]: boolean }?, read grip: boolean? }

local function translation(x: number?, y: number?, z: number?): Mat4
  return lovr.math.newMat4():translate(x or 0, y or 0, z or 0)
end

local function start(definition: typeof(interaction.definition)?): Environment
  local env: Environment = { native = testing.native(), pressed = {}, released = {}, leaves = 0 }
  env.session = testing.start {
    'drops',
    'focus',
    { id = 'interaction', definition = definition or interaction.definition },
  }
  env.consumer = env.session:use(adapter.define {
    name = 'interaction-test',
    requires = { interactionContract.capability, focusContract.capability },
    init = function(context: adapter.Context)
      env.owner = context
      env.interaction = context:require(interactionContract.capability)
      env.focus = context:require(focusContract.capability)
    end,
  })
  function env.newSeat(id: number): Seat
    local seat: Seat = { id = id, dead = false, calls = 0 }
    function seat:setFocus(sink: Sink?): boolean
      self.calls += 1
      self.focus = sink
      return true
    end
    return seat
  end
  local seat = env.newSeat(1)
  env.seat, env.defaultSeat = seat, seat
  require('@lunette').defaultSeat = function(): Seat?
    return env.defaultSeat
  end
  local sink: Sink = { domain = 'window', id = 1, dead = false }
  function sink:button(button: string, isDown: boolean, actualSeat: Seat?)
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
  -- Native sinks compare by what they deliver to, as the handles do.
  local sameTarget = {
    __eq = function(first: Sink, second: Sink): boolean
      return first.domain == second.domain
        and first.id == second.id
        and (first.monitor and first.monitor.id) == (second.monitor and second.monitor.id)
    end,
  }
  function env.window(id: number): Sink
    return setmetatable({ domain = 'window', id = id, dead = false, button = function() end }, sameTarget)
  end
  function env.host(id: string): Sink
    return setmetatable({ domain = 'host', monitor = { id = id }, dead = false, button = function() end }, sameTarget)
  end
  return env
end

local function click(pointer: interactionContract.Pointer, sink: Sink)
  pointer:setButton { pressed = true, sink = sink }
  pointer:setButton { pressed = false }
end

local function surface(env: Environment, z: number?): Surface
  local result: Surface = { dead = false, pose = translation(0, 0, z), width = 1, height = 1 }
  function result:setHighlighted(value: boolean)
    self.highlighted = value
  end
  function result:setPose(value: Mat4)
    self.pose:set(value)
  end
  function result:setSize(width: number)
    self.width = width
  end
  function result:sink(): Sink
    return env.sink
  end
  function result:raycast(): (number, number, number)
    return 10, 20, 1
  end
  return result
end

local function input(fields: InputFields): interactionContract.Input
  return {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = fields.pose or translation(),
    buttons = fields.buttons or {},
    grip = fields.grip or false,
    dt = 0.016,
  }
end

test('a pointer is made only for a context requiring interaction, with tuning merged over the defaults', function()
  local env = start()
  env.session:use(adapter.define {
    name = 'stranger',
    init = function(context: adapter.Context)
      expect.raises(function()
        env.interaction:newPointer(context)
      end, nil, 'a pointer for a context that does not require interaction')
    end,
  })
  local near = env.interaction:newPointer(env.owner, { seat = env.seat, tuning = { reach = 1 } })
  expect.equal(near.seat, env.seat, 'the seat')
  expect.equal(near.tuning.reach, 1, 'the merged reach')
  local default = env.interaction:newPointer(env.owner)
  expect.equal(near.tuning.scrollScale, default.tuning.scrollScale, 'the inherited scroll scale')
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
  env.session:close()
end)

test('two pointers share a grab: pushing, dragging, scaling, and a partner letting go', function()
  local env = start()
  local first, second = env.interaction:newPointer(env.owner), env.interaction:newPointer(env.owner)
  local target = surface(env, -2)
  expect.truthy(first:beginGrab(target, translation()), 'the first grab')
  first:push { deflection = 1, dt = 1 }
  first:dragTo(translation(1))
  local x, _, z = target.pose:getPosition()
  expect.near(x, 1, 1e-5, 'the drag moves the surface with the hand')
  expect.truthy(z < -2, 'the push moves the surface along the ray')
  first:dragTo(translation())
  expect.truthy(second:beginGrab(target, translation(1)), 'the second grab of the same surface')
  second:scaleWith(translation(2))
  expect.near(target.width, 2, 1e-5, 'two hands moving apart scale the surface')
  expect.truthy(first:endGrab(), 'ending a grab answers that something was carried')
  second:scaleWith(translation(2))
  second:dragTo(translation(5))
  expect.near((target.pose:getPosition()), 3, 1e-5, 'the partner letting go turns a scale into a grab')
  env.session:close()
end)

test("an unloading owner's pointers release their buttons, leave, and take their focus back", function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  local target = surface(env, -2)
  pointer:hover(target)
  pointer:setButton { pressed = true, sink = env.sink, surface = target }
  env.consumer:disable()
  expect.equal(env.seat.focus, nil, 'a destroyed pointer withdraws the native focus it gave')
  expect.equal(env.focus:focused(), nil, 'a destroyed pointer is no longer focused')
  expect.truthy(pointer.dead, 'the pointer')
  expect.equal(env.released[1], 'left', 'the held button is released')
  expect.equal(env.leaves, 1, 'the sink is left')
  expect.falsy(target.highlighted, 'the highlight is cleared')
  env.session:close()
end)

test('update presses buttons with focus, and a grip carries the surface rigidly with the hand', function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  local plate = surface(env, -1)
  pointer:update(input { buttons = { left = true, middle = true } }, { plate })
  expect.equal(pointer.hovered, plate, 'the surface the ray hits')
  expect.equal(table.concat(env.pressed, ' '), 'left middle', 'the buttons held')
  expect.equal(env.seat.focus, env.sink, 'a press gives the seat focus to the sink')
  expect.truthy(env.focus:focused(), 'a press gives a focus grant')
  pointer:update(input {}, { plate })
  local initial = lovr.math.newMat4(plate.pose)
  pointer:update(input { grip = true }, { plate })
  expect.equal(pointer.grabbed, plate, 'the grip grabs')
  local moved = translation(0.2, 0.1, 0):rotate(0.8, 0, 1, 0)
  pointer:update(input { grip = true, pose = moved }, { plate })
  local expected = lovr.math.newMat4(moved):mul(initial)
  for _, point in { { 0, 0, 0, 1 }, { 1, 0, 0, 0 }, { 0, 0, 1, 0 } } do
    local x, y, z = plate.pose:mul(table.unpack(point))
    local ex, ey, ez = expected:mul(table.unpack(point))
    expect.near(x, ex, 1e-5, 'the surface follows the hand in x')
    expect.near(y, ey, 1e-5, 'the surface follows the hand in y')
    expect.near(z, ez, 1e-5, 'the surface follows the hand in z')
  end
  pointer:update(input {}, { plate })
  expect.equal(pointer.grabbed, nil, 'releasing the grip drops the surface')
  env.session:close()
end)

test('a drive hook remaps input, a constrain hook places what is carried, and focusOnPress can be off', function()
  local env = start(interaction.define {
    name = 'hooked-interaction',
    focusOnPress = false,
    drive = function(
      pointer: interactionContract.Pointer,
      given: interactionContract.Input,
      surfaces: { interactionContract.Surface },
      base: interaction.DriveBase
    )
      base(pointer, {
        origin = given.origin,
        direction = given.direction,
        pose = given.pose,
        buttons = { right = given.buttons.left },
        grip = given.grip,
        dt = given.dt,
      }, surfaces)
    end,
    constrain = function(target: interactionContract.Surface, pose: Mat4, base: interaction.ConstrainBase): Mat4
      local x, _, z = base(target, pose):getPosition()
      return translation(x, 1.5, z)
    end,
  })
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat })
  local plate = surface(env, -1)
  pointer:update(input { buttons = { left = true } }, { plate })
  expect.equal(table.concat(env.pressed, ' '), 'right', 'the drive hook remapped the trigger')
  expect.equal(env.seat.focus, nil, 'focusOnPress = false gives no native focus')
  expect.equal(env.focus:focused(), nil, 'focusOnPress = false gives no focus grant')
  pointer:update(input {}, { plate })
  pointer:update(input { grip = true }, { plate })
  pointer:update(input { grip = true, pose = translation(2, 4) }, { plate })
  local x, y = plate.pose:getPosition()
  expect.near(x, 2, 1e-5, 'the constraint allows the slide')
  expect.near(y, 1.5, 1e-5, 'the constraint keeps the height')
  env.session:close()
end)

test(
  'a pointer keeps one target per app, refocusing it after a local field and replacing it for another app',
  function()
    local env = start()
    local seat = env.newSeat(2)
    local pointer = env.interaction:newPointer(env.owner, { seat = seat })
    click(pointer, env.window(11))
    local target = env.focus:focused()
    local field = env.focus:register(env.owner, {
      kind = 'local',
      receiver = {
        key = function(): boolean
          return true
        end,
        text = function(): boolean
          return true
        end,
      },
      wantsKeyboard = true,
    })
    expect.truthy(field:focus(), 'the local field focuses')
    expect.equal(seat.focus, nil, 'the local field clears native focus')
    click(pointer, env.window(11))
    expect.equal(env.focus:focused(), target, 'a fresh sink wrapper refocuses the existing target')
    expect.equal(seat.focus.id, 11, 'native focus returns to the app')
    click(pointer, env.window(12))
    expect.truthy(target.dead, 'another app replaces the previous target')
    expect.equal(#env.focus:inspect().registrations, 2, 'one pointer target and one local field')
    env.consumer:disable()
    expect.equal(#env.focus:inspect().registrations, 0, 'owner teardown leaves no targets')
    expect.equal(seat.focus, nil, 'owner teardown clears native focus')
    env.session:close()
  end
)

test('host targets route focus without asking a compositor seat to focus a monitor', function()
  local env = start()
  local seat = env.newSeat(2)
  local pointer = env.interaction:newPointer(env.owner, { seat = seat })
  click(pointer, env.host 'display-a')
  local target = env.focus:focused()
  expect.truthy(target, 'the host route is focused')
  click(pointer, env.host 'display-b')
  expect.truthy(target.dead, 'another monitor replaces the target')
  pointer:focus(nil)
  expect.equal(env.focus:focused(), nil, 'explicit blur clears the host route')
  pointer:destroy()
  expect.equal(seat.calls, 0, 'host focus makes no native seat call')
  env.session:close()
end)

test('a pointer without a seat follows the default seat', function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner)
  pointer:focus(env.window(11))
  expect.equal(env.seat.focus.id, 11, 'the default seat receives focus')
  local replacement = env.newSeat(4)
  env.defaultSeat = replacement
  pointer:focus(env.window(11))
  expect.equal(env.seat.focus, nil, 'changing the default seat clears the previous authority')
  expect.equal(replacement.focus.id, 11, 'the new default seat receives focus')
  pointer:destroy()
  expect.equal(replacement.focus, nil, 'pointer destruction clears the resolved default seat')
  env.session:close()
end)

return test
