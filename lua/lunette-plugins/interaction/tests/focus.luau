local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local interactionContract = require '@lunette-contracts/interaction'
local focusContract = require '@lunette-contracts/focus'
local interaction = require '@lunette-plugins/interaction'

local test = testing.suite()

local function start(definition)
  local env = { native = testing.native(), calls = {}, seats = {}, buttons = {} }
  local function seat(id)
    local result = { id = id, dead = false }
    function result:setFocus(sink)
      env.calls[#env.calls + 1] = { seat = id, sink = sink }
      env.seats[id] = sink
      return true
    end
    return result
  end
  env.seat = seat
  env.defaultSeat = seat(1)
  lunette.defaultSeat = function()
    return env.defaultSeat
  end
  env.session = testing.start {
    'drops',
    'focus',
    { id = 'interaction', definition = definition or interaction.definition },
  }
  env.consumer = env.session:use(plugin.define {
    name = 'interaction-focus-test',
    requires = { interaction = interactionContract.capability, focus = focusContract.capability },
    init = function(context)
      env.owner = context
      env.interaction = context:require(interactionContract.capability)
      env.focus = context:require(focusContract.capability)
    end,
  })
  function env.window(id)
    local sink = { domain = 'window', id = id, dead = false }
    function sink:button(button, pressed, actualSeat)
      env.buttons[#env.buttons + 1] = { button = button, pressed = pressed, seat = actualSeat }
    end
    return sink
  end
  function env.host(id)
    local sink = env.window(1)
    sink.domain, sink.id, sink.monitor = 'host', nil, { id = id }
    return sink
  end
  function env.localField()
    return env.focus:register(env.owner, {
      kind = 'local',
      receiver = {
        key = function()
          return true
        end,
        text = function()
          return true
        end,
      },
      wantsKeyboard = true,
    })
  end
  return env
end

local function click(pointer, sink)
  pointer:setButton { pressed = true, sink = sink }
  pointer:setButton { pressed = false }
end

local function registrations(env)
  return #env.focus:inspect().registrations
end

test('clicking the same app after a local field refocuses its existing target', function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat(2) })
  local sink = env.window(11)
  click(pointer, sink)
  local target = env.focus:focused()
  expect.truthy(target, 'the app target')
  local field = env.localField()
  expect.truthy(field:focus(), 'the local field focuses')
  expect.equal(env.seats[2], nil, 'the local field clears native focus')
  click(pointer, env.window(11))
  expect.equal(env.focus:focused(), target, 'the existing app target refocuses with a fresh sink wrapper')
  expect.equal(env.seats[2].id, 11, 'native focus returns to the app')
  expect.equal(registrations(env), 2, 'one pointer target and one local field')
  env.session:close()
end)

test('destroying a superseded pointer cannot clear the newer holder of the same seat id', function()
  local env = start()
  local first = env.interaction:newPointer(env.owner, { seat = env.seat(2) })
  local second = env.interaction:newPointer(env.owner, { seat = env.seat(2) })
  first:focus(env.window(11))
  local old = env.focus:focused()
  second:focus(env.window(12))
  local current = env.focus:focused()
  expect.truthy(current ~= old, 'each pointer has its own target')
  local calls = #env.calls
  first:focus(nil)
  expect.equal(#env.calls, calls, 'blurring the superseded pointer makes no native withdrawal')
  expect.equal(env.focus:focused(), current, 'blurring the superseded pointer preserves the current route')
  first:focus(env.window(11))
  second:focus(env.window(12))
  expect.equal(env.focus:focused(), current, 'supersession reuses the newer target')
  calls = #env.calls
  first:destroy()
  expect.equal(#env.calls, calls, 'destroying the superseded pointer makes no native withdrawal')
  expect.equal(env.focus:focused(), current, 'the newer route remains current')
  expect.equal(env.seats[2].id, 12, 'the newer native holder remains')
  expect.equal(registrations(env), 1, 'the old pointer target is destroyed')
  second:destroy()
  expect.equal(env.seats[2], nil, 'destroying the current holder clears its seat')
  env.session:close()
end)

test('pointers on independent seats keep separate native authority', function()
  local env = start()
  local first = env.interaction:newPointer(env.owner, { seat = env.seat(2) })
  local second = env.interaction:newPointer(env.owner, { seat = env.seat(3) })
  first:focus(env.window(11))
  second:focus(env.window(12))
  local current = env.focus:focused()
  first:destroy()
  expect.equal(env.seats[2], nil, 'only the first seat clears')
  expect.equal(env.seats[3].id, 12, 'the second seat retains focus')
  expect.equal(env.focus:focused(), current, 'the second route remains current')
  second:destroy()
  expect.equal(env.seats[3], nil, 'the second seat clears on its own destruction')
  env.session:close()
end)

test('host targets route focus without asking a compositor seat to focus a monitor', function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat(2) })
  click(pointer, env.host 'display-a')
  local target = env.focus:focused()
  expect.truthy(target, 'the host route is focused')
  click(pointer, env.host 'display-a')
  expect.equal(env.focus:focused(), target, 'monitor identity reuses the host target')
  expect.equal(#env.calls, 0, 'host focus makes no native seat call')
  click(pointer, env.host 'display-b')
  expect.truthy(env.focus:focused() ~= target, 'another monitor replaces the target')
  expect.truthy(target.dead, 'the previous monitor target is destroyed')
  expect.equal(registrations(env), 1, 'one target remains after the monitor changes')
  pointer:focus(nil)
  expect.equal(env.focus:focused(), nil, 'explicit blur clears the host route')
  pointer:destroy()
  expect.equal(#env.calls, 0, 'host blur and destroy make no native seat call')
  local defaultPointer = env.interaction:newPointer(env.owner)
  click(defaultPointer, env.host 'display-a')
  expect.truthy(env.focus:focused(), 'a host route without an explicit seat focuses')
  defaultPointer:destroy()
  expect.equal(#env.calls, 0, 'a host route without a seat grants no default-seat authority')
  env.session:close()
end)

test('a pointer without a seat establishes and clears authority on the default seat', function()
  local env = start()
  local pointer = env.interaction:newPointer(env.owner)
  pointer:focus(env.window(11))
  local target = env.focus:focused()
  expect.equal(env.seats[1].id, 11, 'the default seat receives focus')
  pointer:focus(nil)
  expect.equal(env.seats[1], nil, 'explicit blur clears the default seat')
  expect.equal(env.focus:focused(), nil, 'the route is blurred')
  expect.equal(registrations(env), 1, 'blur preserves the reusable target')
  pointer:focus(env.window(11))
  expect.equal(env.focus:focused(), target, 'explicit refocus reuses the target')
  env.defaultSeat = env.seat(4)
  pointer:focus(env.window(11))
  expect.equal(env.seats[1], nil, 'changing the default seat clears the previous authority')
  expect.equal(env.seats[4].id, 11, 'the new default seat receives focus')
  pointer:destroy()
  expect.equal(env.seats[4], nil, 'pointer destruction clears the resolved default seat')
  expect.equal(registrations(env), 0, 'the default-seat target is destroyed')
  env.session:close()
end)

test(
  'one pointer reuses stable app identities and replaces changed targets without accumulating registrations',
  function()
    local env = start()
    local pointer = env.interaction:newPointer(env.owner, { seat = env.seat(2) })
    pointer:focus(env.window(11))
    local target = env.focus:focused()
    for _ = 1, 25 do
      click(pointer, env.window(11))
      expect.equal(env.focus:focused(), target, 'fresh wrappers preserve the target')
      expect.equal(registrations(env), 1, 'repeated focus retains one registration')
    end
    for id = 12, 36 do
      pointer:focus(env.window(id))
      expect.truthy(target.dead, 'the previous app target is destroyed')
      target = env.focus:focused()
      expect.equal(registrations(env), 1, 'changing apps retains one registration')
    end
    env.consumer:disable()
    expect.truthy(target.dead, 'owner teardown destroys the remaining target')
    expect.equal(registrations(env), 0, 'owner teardown leaves no targets')
    expect.equal(env.seats[2], nil, 'owner teardown clears native focus')
    env.session:close()
  end
)

test('explicit focus remains available with focusOnPress disabled and legacy surfaces still receive presses', function()
  local env = start(interaction.define { name = 'manual-focus', focusOnPress = false })
  local pointer = env.interaction:newPointer(env.owner, { seat = env.seat(2) })
  local sink = env.window(11)
  click(pointer, sink)
  expect.equal(env.focus:focused(), nil, 'pressing an app does not focus it automatically')
  expect.equal(registrations(env), 0, 'disabled focusOnPress makes no target')
  pointer:focus(sink)
  local target = env.focus:focused()
  expect.truthy(target, 'explicit focus still grants the route')
  local presses, releases = 0, 0
  local surface = {
    dead = false,
    onPress = function(_self, _x, _y, actualPointer)
      expect.equal(actualPointer, pointer, 'the legacy press receives the pointer')
      presses += 1
    end,
    onRelease = function()
      releases += 1
    end,
  }
  pointer:setButton { pressed = true, surface = surface }
  pointer:setButton { pressed = false }
  expect.equal(presses, 1, 'the legacy surface receives its press')
  expect.equal(releases, 1, 'the legacy surface receives its release')
  expect.equal(env.focus:focused(), target, 'the legacy press leaves explicit native focus unchanged')
  pointer:destroy()
  env.session:close()
end)

return test
