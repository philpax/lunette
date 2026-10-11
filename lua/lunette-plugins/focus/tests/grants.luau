local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/focus'
local test = testing.suite()

type Sink = { dead: boolean, domain: 'window', id: number, key: (() -> boolean)?, setModifiers: (() -> boolean)? }
type Seat = {
  id: number,
  dead: boolean,
  calls: { { sink: Sink? } },
  refuse: boolean?,
  focus: Sink?,
  setFocus: (Seat, Sink?) -> boolean,
}
type Context = typeof(testing.start({}):observe(contract.capability).context)
type Observed = typeof(testing.start({}):observe(contract.capability))
type Environment = {
  native: typeof(testing.native()),
  heard: { contract.Change },
  session: typeof(testing.boot {})?,
  first: Observed?,
  second: Observed?,
  focus: contract.Service?,
  owner: Context?,
  other: Context?,
  left: Seat?,
  right: Seat?,
  sink: Sink?,
  otherSink: Sink?,
  nativeTarget: (Environment, Context, Seat, Sink) -> contract.TargetHandle,
  localTarget: (Environment) -> contract.TargetHandle,
}

local function start(): Environment
  local env: Environment = { native = testing.native(), heard = {} }
  env.session = testing.boot({ 'frame', 'focus' }, { native = env.native })
  env.first = env.session:observe(contract.capability)
  env.second = env.session:observe(contract.capability)
  env.focus, env.owner, env.other = env.first.service, env.first.context, env.second.context
  local function seat(id: number): Seat
    local value: Seat = { id = id, dead = false, calls = {} }
    function value:setFocus(sink: Sink?): boolean
      self.calls[#self.calls + 1] = { sink = sink }
      if self.refuse then
        return false
      end
      self.focus = sink
      return true
    end
    return value
  end
  env.left, env.right = seat(11), seat(12)
  env.sink, env.otherSink = { dead = false, domain = 'window', id = 1 }, { dead = false, domain = 'window', id = 2 }
  for _, sink in { env.sink, env.otherSink } do
    sink.key = function(): boolean
      return true
    end
    sink.setModifiers = function(): boolean
      return true
    end
  end
  function env:nativeTarget(owner: Context, seatValue: Seat, sink: Sink): contract.TargetHandle
    return self.focus:register(owner, { kind = 'native', seat = seatValue, sink = sink })
  end
  function env:localTarget(): contract.TargetHandle
    return self.focus:register(self.owner, {
      kind = 'local',
      wantsKeyboard = true,
      receiver = {
        key = function(): boolean
          return false
        end,
        text = function(): boolean
          return false
        end,
      },
    })
  end
  env.focus:onChanged(env.owner, {
    run = function(change: contract.Change)
      env.heard[#env.heard + 1] = change
    end,
  })
  return env
end

test('one route is focused at a time, and destroying it restores nothing', function()
  local env = start()
  local app = env:nativeTarget(env.owner, env.left, env.sink)
  local field = env:localTarget()
  expect.truthy(app:focus(), 'the application focuses')
  expect.equal(env.left.focus, env.sink, 'native window focus is established')
  expect.equal(env.focus:focused(), app, 'the registered route is current')
  local announced = #env.heard
  expect.truthy(app:focus(), 'refocusing the same handle succeeds')
  expect.equal(#env.heard, announced, 'idempotent focus')
  expect.truthy(field:focus(), 'the local field focuses')
  expect.equal(env.left.focus, nil, 'local input clears the native seat')
  expect.equal(env.heard[#env.heard].target, field, 'the change identifies the new route')
  app:destroy()
  expect.equal(env.focus:focused(), field, 'destroying an old route does not clear the field')
  field:destroy()
  expect.equal(env.focus:focused(), nil, 'no prior application is restored')
  expect.falsy(field:focus(), 'a dead handle stays inert')
  env.session:close()
end)

test('each native seat keeps its own authority, and an older holder cannot clear a newer one', function()
  local env = start()
  local first = env:nativeTarget(env.owner, env.left, env.sink)
  local second = env:nativeTarget(env.owner, env.right, env.otherSink)
  first:focus()
  second:focus()
  expect.equal(env.left.focus, env.sink, 'the first seat retains native authority')
  second:destroy()
  expect.equal(env.right.focus, nil, 'the destroyed seat clears')
  expect.equal(env.left.focus, env.sink, 'the other seat remains independent')
  local newer = env:nativeTarget(env.other, env.left, env.otherSink)
  newer:focus()
  first:destroy()
  expect.equal(env.left.focus, env.otherSink, 'an older target cannot withdraw newer native authority')
  env.second.instance:disable()
  expect.equal(env.left.focus, nil, 'owner unload clears its authority')
  expect.equal(env.focus:focused(), nil, 'owner unload clears the current route')
  env.session:close()
end)

test('a seat refusing focus leaves the previous route current', function()
  local env = start()
  local field = env:localTarget()
  field:focus()
  local announced = #env.heard
  env.left.refuse = true
  expect.falsy(env:nativeTarget(env.owner, env.left, env.sink):focus(), 'native focus refusal propagates')
  expect.equal(env.focus:focused(), field, 'the earlier route remains current')
  expect.equal(#env.heard, announced, 'no refused transition is announced')
  env.session:close()
end)

test('a dead native sink clears focus at the next frame', function()
  local env = start()
  env:nativeTarget(env.owner, env.left, env.sink):focus()
  local announced = #env.heard
  env.sink.dead = true
  env.session:update()
  expect.equal(#env.heard, announced + 1, 'the loss is announced')
  expect.equal(env.heard[#env.heard].kind, 'none', 'the loss clears input intent')
  expect.equal(env.left.focus, nil, 'native focus is withdrawn')
  env.session:close()
end)

test('malformed registrations and activations are rejected before they take effect', function()
  local env = start()
  local before = #env.focus:inspect().registrations
  expect.raises(function()
    env.focus:register(env.owner, { kind = 'other' })
  end, 'kind is native or local', 'an unknown target kind')
  expect.equal(#env.focus:inspect().registrations, before, 'invalid data acquires no registration')
  local input = env.focus:newSource(env.owner)
  expect.equal(input:key({ code = 30, modifiers = { 'shift', 1 } }).kind, 'refused', 'a malformed activation')
  env.session:close()
end)

return test
