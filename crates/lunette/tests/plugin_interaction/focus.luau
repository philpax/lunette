-- The focus provider: grants held per owner and seat, and change listeners.
local native = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'

local reported = {}
native.reportError = function(fields)
  reported[#reported + 1] = fields.context .. ': ' .. fields.message
end

local runtime = plugin.runtime()
runtime:use(require('@lunette-plugins/focus').definition, {}):enable()
local service, owner, other
local function consumer(name, assign)
  local instance = runtime:use(
    plugin.define {
      name = name,
      requires = { focus = contract.capability },
      init = function(ctx)
        service = ctx:require(contract.capability)
        assign(ctx)
      end,
    },
    {}
  )
  instance:enable()
  return instance
end
local first = consumer('focus-1', function(ctx)
  owner = ctx
end)
local second = consumer('focus-2', function(ctx)
  other = ctx
end)

local function newSeat()
  local seat = { dead = false }
  function seat:setFocus(sink)
    self.focus = sink
  end
  return seat
end
local left, right = newSeat(), newSeat()
local sink, otherSink = { dead = false }, { dead = false }

local heard = {}
local listener = service:onChanged(owner, {
  run = function(change)
    heard[#heard + 1] = change
  end,
})

-- An owner holds one grant per seat, and moving it answers the same effect.
local grant = service:setFocus(owner, { seat = left, sink = sink })
assert(left.focus == sink and service:focused() == left)
assert(#heard == 1 and heard[1].seat == left and heard[1].sink == sink)
assert(not pcall(function()
  heard[1].seat = right
end), 'a change is frozen')
assert(service:setFocus(owner, { seat = left, sink = otherSink }) == grant)
assert(left.focus == otherSink and select(2, service:focused()) == otherSink)
assert(#heard == 2)
assert(service:setFocus(owner, { seat = left, sink = otherSink }) == grant)
assert(#heard == 2, 'a grant that changes nothing is not announced')

-- Another seat is another grant, and the most recent grant is answered.
local rightGrant = service:setFocus(owner, { seat = right, sink = sink })
assert(rightGrant ~= grant and service:focused() == right and left.focus == otherSink)
rightGrant:dispose()
assert(right.focus == nil and service:focused() == nil, 'disposing a grant takes its focus back')
assert(left.focus == otherSink, 'the other seat keeps its focus')

-- A nil sink withdraws the grant without ending it.
assert(service:setFocus(owner, { seat = left }) == grant)
assert(left.focus == nil and service:focused() == nil)
assert(service:setFocus(owner, { seat = left, sink = sink }) == grant)
assert(left.focus == sink)

-- A later holder of a seat keeps it when the earlier one ends.
local taken = service:setFocus(other, { seat = left, sink = otherSink })
assert(left.focus == otherSink and service:focused() == left)
grant:dispose()
assert(left.focus == otherSink, 'an earlier grant that gave the seat away takes nothing back')
second:disable()
assert(left.focus == nil and service:focused() == nil, 'an unloading owner takes its focus back')
assert(taken)
second:enable()

-- A listener that raises is reported, and the others still hear the change.
local after = 0
local failing = service:onChanged(owner, {
  run = function()
    error 'focus listener failure'
  end,
})
service:onChanged(owner, {
  run = function()
    after += 1
  end,
})
service:setFocus(owner, { seat = right, sink = sink })
assert(after == 1 and #reported == 1 and reported[1]:find('focus listener failure', 1, true), tostring(reported[1]))
failing:dispose()
listener:dispose()

assert(not pcall(function()
  service:setFocus(owner, { seat = left, sink = sink, holder = true })
end), 'an unknown field raises')
assert(not pcall(function()
  service:onChanged(owner, { run = 'no' })
end), 'a run that is not a function raises')
first:disable()
assert(right.focus == nil and service:focused() == nil)
runtime:close()
