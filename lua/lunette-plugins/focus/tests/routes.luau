local testing = require '@testing'
local expect = testing.expect
local routes = require '@lunette-plugins/focus/routes'

local test = testing.suite()

local function fixture()
  local env = { calls = {}, defaultId = 1 }
  function env.seat(id)
    local seat = { id = id, dead = false }
    function seat:setFocus(sink)
      env.calls[#env.calls + 1] = { id, sink }
      return not self.refuse
    end
    return seat
  end
  env.default = env.seat(1)
  env.state = routes.new(function()
    return env.default
  end)
  function env.native(id, seat)
    return { target = { kind = 'native', seat = seat, sink = { id = id, domain = 'window', dead = false } } }
  end
  function env.localTarget()
    return { target = { kind = 'local', receiver = {}, wantsKeyboard = true } }
  end
  return env
end

test('focus has a single route and disposal does not restore an older route', function()
  local env = fixture()
  local first, second = env.native(10), env.localTarget()
  expect.truthy(routes.focus(env.state, first))
  expect.equal(env.state.current, first)
  expect.truthy(routes.focus(env.state, second))
  expect.equal(env.state.current, second)
  expect.equal(#env.calls, 2, 'window focus is established then cleared for a local target')
  expect.equal(env.calls[2][2], nil, 'the local target clears native keyboard focus')
  expect.falsy(routes.blur(env.state, first), 'an older target cannot blur the current local route')
  expect.equal(env.state.current, second)
  expect.truthy(routes.blur(env.state, second))
  expect.equal(env.state.current, nil, 'blurring local input does not restore the application')
  expect.truthy(routes.focus(env.state, first), 'explicit application interaction refocuses it')
  local revision = env.state.revision
  expect.truthy(routes.focus(env.state, first))
  expect.equal(env.state.revision, revision, 'the same live handle is idempotent')
end)

test('nil and explicit default seats share authority in both supersession orders', function()
  for _, explicitFirst in ipairs { false, true } do
    local env = fixture()
    local first = env.native(10, if explicitFirst then env.seat(1) else nil)
    local second = env.native(20, if explicitFirst then nil else env.seat(1))
    expect.truthy(routes.focus(env.state, first))
    expect.truthy(routes.focus(env.state, second))
    expect.falsy(routes.blur(env.state, first), 'superseded wrappers cannot clear the default seat')
    expect.equal(#env.calls, 2, 'supersession establishes focus without stale inverse')
    expect.equal(env.state.current, second)
    expect.truthy(routes.blur(env.state, second))
    expect.equal(env.calls[3][1], 1)
    expect.equal(env.calls[3][2], nil, 'the authoritative default seat is cleared')
  end
end)

test('independent native seats retain authority and disposal clears only the intended seat', function()
  local env = fixture()
  local first, second = env.native(10, env.seat(2)), env.native(20, env.seat(3))
  expect.truthy(routes.focus(env.state, first))
  expect.truthy(routes.focus(env.state, second))
  expect.truthy(routes.blur(env.state, first), 'the noncurrent seat still has its own authority')
  expect.equal(env.state.current, second)
  expect.equal(env.calls[3][1], 2)
  expect.equal(env.calls[3][2], nil)
  local localRoute = env.localTarget()
  expect.truthy(routes.focus(env.state, localRoute))
  expect.equal(env.calls[4][1], 3, 'only the previous current native seat is cleared')
  expect.equal(env.state.current, localRoute)
end)

test('native window refusal leaves the previous route and authority intact', function()
  local env = fixture()
  local first, refusedSeat = env.native(10), env.seat(2)
  refusedSeat.refuse = true
  local refused = env.native(20, refusedSeat)
  routes.focus(env.state, first)
  local revision = env.state.revision
  expect.falsy(routes.focus(env.state, refused))
  expect.equal(env.state.current, first)
  expect.equal(env.state.revision, revision)
  expect.equal(env.state.seats[1].route, first)
  expect.equal(env.state.seats[2], nil)
end)

test('host routes never attempt unsupported native seat focus', function()
  local env = fixture()
  local target = {
    target = {
      kind = 'native',
      seat = env.seat(2),
      sink = { domain = 'host', monitor = { id = 'fixture-monitor' }, dead = false },
    },
  }
  expect.truthy(routes.focus(env.state, target))
  expect.equal(#env.calls, 0)
  expect.truthy(routes.blur(env.state, target))
  expect.equal(#env.calls, 0)
end)

test('a refused native inverse clears bookkeeping without restoring an old route', function()
  local env = fixture()
  local target = env.native(10)
  routes.focus(env.state, target)
  env.default.refuse = true
  expect.raises(function()
    routes.blur(env.state, target)
  end, 'refused', 'native focus clear refusal is observable')
  expect.equal(env.state.current, nil)
  expect.equal(env.state.seats[1], nil)
end)

test('deterministic focus sequences agree with an independent single-route and per-seat model', function()
  for seed = 1, 24 do
    local env = fixture()
    local targets =
      { env.native(10, env.seat(2)), env.native(20, env.seat(2)), env.native(30, env.seat(3)), env.localTarget() }
    local current, revision = nil, 0
    local authority = {}
    local sequence = seed
    for step = 1, 160 do
      sequence = (sequence * 48271) % 2147483647
      local index = sequence % #targets + 1
      sequence = (sequence * 48271) % 2147483647
      local focus = sequence % 3 ~= 0
      local before = current
      if focus then
        if current ~= index then
          current, revision = index, revision + 1
          if index == 4 then
            for seat, holder in pairs(authority) do
              if holder == before then
                authority[seat] = nil
              end
            end
          else
            authority[if index == 3 then 3 else 2] = index
          end
        end
        routes.focus(env.state, targets[index])
      else
        if current == index then
          current, revision = nil, revision + 1
        end
        for seat, holder in pairs(authority) do
          if holder == index then
            authority[seat] = nil
          end
        end
        routes.blur(env.state, targets[index])
      end
      expect.equal(
        env.state.current,
        if current then targets[current] else nil,
        'current after sequence ' .. seed .. ':' .. step
      )
      expect.equal(env.state.revision, revision, 'revision after sequence ' .. seed .. ':' .. step)
      for _, seat in { 2, 3 } do
        local actual = env.state.seats[seat]
        local expected = authority[seat]
        expect.equal(actual and actual.route, if expected then targets[expected] else nil, 'authority ' .. seat)
      end
    end
  end
end)

test('a reentrant native focus callback cannot replace the route it just selected', function()
  local env = fixture()
  local seat = env.seat(2)
  local first, second = env.native(10, seat), env.native(20, seat)
  local nativeFocus = seat.setFocus
  local inside = false
  function seat:setFocus(sink)
    nativeFocus(self, sink)
    if not inside then
      inside = true
      routes.focus(env.state, second)
    end
    return true
  end
  expect.falsy(routes.focus(env.state, first), 'the original transition is superseded')
  expect.equal(env.state.current, second, 'the newer route remains current')
  expect.equal(env.state.seats[2].route, second, 'the newer native authority remains current')
  expect.equal(env.state.revision, 1, 'no stale continuation commits')
end)

return test
