-- Retained dead sources must not retain routing callbacks or their captured state.
local testing = require '@testing'
local sourceModule = require '../source'
local expect = testing.expect
local test = testing.suite()

local function retainedSource(frozen, duringDispose)
  local weak = setmetatable({}, { __mode = 'v' })
  local source, inverse
  local calls = { cancelled = 0, disposed = 0 }
  do
    local routingState = { revision = 1 }
    local snapshot = function()
      return { revision = routingState.revision }
    end
    local routing = {
      snapshot = snapshot,
      keymapSeat = function()
        expect.equal(routingState.revision, 1, 'live routing capture')
        return nil
      end,
      listen = function()
        return function()
          expect.truthy(source.dead, 'source state clears before listener cancellation')
          calls.cancelled += 1
        end
      end,
      dispose = function()
        expect.truthy(source.dead, 'source state clears before provider notification')
        calls.disposed += 1
        if duringDispose then
          duringDispose(source, weak)
        end
        inverse()
      end,
    }
    local options = { mode = 'virtual' }
    if frozen then
      table.freeze(options)
    end
    weak.routing, weak.snapshot, weak.routingState = routing, snapshot, routingState
    weak.options = options
    source, inverse = sourceModule.new({
      owns = function()
        return true
      end,
    }, {}, options, routing)
  end
  return source, inverse, weak, calls
end

local function collected(weak)
  testing.collect()
  expect.equal(weak.routing, nil, 'the routing table is collected')
  expect.equal(weak.snapshot, nil, 'the routing callback is collected')
  expect.equal(weak.routingState, nil, 'the routing capture is collected')
  expect.equal(weak.options, nil, 'the options table is collected')
end

for _, frozen in { false, true } do
  local label = if frozen then 'frozen' else 'plain'
  test(
    'public destruction releases callbacks from ' .. label .. ' options while the handle remains retained',
    function()
      testing.native()
      local source, inverse, weak, calls = retainedSource(frozen)
      testing.collect()
      expect.truthy(weak.routingState, 'the live source retains routing captures')
      expect.truthy(source:destroy(), 'public destruction')
      collected(weak)
      expect.equal(calls.cancelled, 1, 'the route listener is cancelled')
      expect.equal(calls.disposed, 1, 'the provider is notified once')
      inverse()
      expect.falsy(source:destroy(), 'repeated destruction is inert')
      expect.equal(calls.disposed, 1, 'the owner inverse does not notify the provider again')
      expect.truthy(source.dead, 'the dead handle remains retained')
    end
  )

  test('the owner inverse releases callbacks from ' .. label .. ' options while the handle remains retained', function()
    testing.native()
    local source, inverse, weak, calls = retainedSource(frozen)
    inverse()
    collected(weak)
    expect.truthy(source.dead, 'the owner inverse destroys the retained handle')
    expect.equal(calls.cancelled, 1, 'the route listener is cancelled')
    expect.equal(calls.disposed, 0, 'the owner inverse skips recursive provider disposal')
    inverse()
    expect.falsy(source:destroy(), 'the handle stays inert')
  end)
end

test('public destruction detaches callback references before provider notification', function()
  testing.native()
  local source, inverse, weak, calls = retainedSource(false, function(dead, retained)
    collected(retained)
    expect.equal(dead:key({ code = 30 }).kind, 'refused', 'keys during provider notification are inert')
    expect.equal(dead:text('ignored').kind, 'refused', 'text during provider notification is inert')
    expect.equal(dead:keymapSeat(), nil, 'keymap queries during provider notification are inert')
    dead:beginBatch(1)
    expect.truthy(dead:reset(), 'reset during provider notification has no pending inverses')
  end)
  expect.truthy(source:destroy(), 'public destruction succeeds')
  collected(weak)
  expect.equal(calls.disposed, 1, 'one provider notification')
  inverse()
end)

return test
