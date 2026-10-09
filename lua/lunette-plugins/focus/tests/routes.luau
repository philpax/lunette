local testing = require '@testing'
local expect = testing.expect
local routes = require '@lunette-plugins/focus/routes'

local test = testing.suite()

local function fixture()
  local env = {}
  function env.seat(id)
    local seat = { id = id, dead = false }
    function seat:setFocus()
      return true
    end
    return seat
  end
  env.state = routes.new()
  function env.native(id, seat)
    return { target = { kind = 'native', seat = seat, sink = { id = id, domain = 'window', dead = false } } }
  end
  function env.localTarget()
    return { target = { kind = 'local', receiver = {}, wantsKeyboard = true } }
  end
  return env
end

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

return test
