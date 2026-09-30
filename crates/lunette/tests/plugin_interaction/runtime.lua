local function matrix(value)
  local m = { x = value and value.x or 0, y = value and value.y or 0, z = value and value.z or 0 }
  function m:getPosition()
    return self.x, self.y, self.z
  end
  function m:getOrientation()
    return 0, 0, 1, 0
  end
  function m:set(other)
    self.x, self.y, self.z = other.x, other.y, other.z
    return self
  end
  function m:invert()
    self.x, self.y, self.z = -self.x, -self.y, -self.z
    return self
  end
  function m:mul(other)
    self.x += other.x
    self.y += other.y
    self.z += other.z
    return self
  end
  function m:translate(x, y, z)
    self.x += x
    self.y += y
    self.z += z
    return self
  end
  return m
end
lovr = { math = { newMat4 = matrix } }
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/interaction'
local runtime = plugin.runtime()
local panels = runtime:use(require '@lunette-plugins/panels', {})
panels:enable()
local provider = runtime:use(require '@lunette-plugins/interaction', {})
provider:enable()
local service, owner
local consumer = runtime:use(
  plugin.define(function(v)
    return v
  end, { interaction = contract.capability }, {}, function(ctx)
    service, owner = ctx:require(contract.capability), ctx
  end),
  {}
)
consumer:enable()
local wrongOwner = runtime:use(
  plugin.define(function(v)
    return v
  end, {}, {}, function(ctx)
    assert(not pcall(function()
      service:newPointer(ctx)
    end))
  end),
  {}
)
wrongOwner:enable()
assert(#service:pointers() == 0)
local weakResources = setmetatable({}, { __mode = 'v' })
for cycle = 1, 12 do
  do
    local pointer = service:newPointer(owner)
    weakResources[1] = pointer
    assert(pointer:destroy())
    assert(not pointer:destroy())
  end
  collectResources()
  collectResources()
  assert(weakResources[1] == nil, 'destroyed pointer retained by active owner')
end
local down, up, leaves = 0, 0, 0
local seat = {
  dead = false,
  setFocus = function(self, sink)
    self.focus = sink
  end,
}
local sink = { dead = false }
function sink:button(_, pressed, actualSeat)
  assert(actualSeat == seat)
  if pressed then
    down += 1
  else
    up += 1
  end
end
function sink:leave(actualSeat)
  assert(actualSeat == seat)
  leaves += 1
end
local target = { dead = false, pose = matrix { z = -2 }, width = 1, height = 1 }
function target:setHighlighted(value)
  self.highlighted = value
end
function target:setPose(value)
  self.pose:set(value)
end
function target:setSize(width)
  self.width = width
end
function target:sink()
  return sink
end
local first = service:newPointer(owner, { seat = seat })
local second = service:newPointer(owner)
first:hover(target)
assert(first.hovered == target and target.highlighted)
first:setButton(true, sink, target)
assert(down == 1 and first.pressed and seat.focus == sink)
assert(service:focused() == seat)
assert(first:beginGrab(target, matrix()))
assert(first.grabbed == target and first.grab)
first:push(1, 1)
assert(first.grab.pushed > 0)
first:dragTo(matrix { x = 1 })
assert(target.pose.x == 1)
-- The unmanaged pose input supplies positions for two-handed resizing.
first:update({ origin = {}, direction = {}, pose = matrix(), grip = true, trigger = false }, {})
assert(second:beginGrab(target, matrix { x = 1 }))
assert(second.scaling and second.scaling.partner == first)
second:scaleWith(matrix { x = 2 })
assert(target.width == 2)
assert(not first:endGrab())
assert(first.grabbed == nil)
second:scaleWith(matrix { x = 2 })
assert(second.scaling == nil and second.grab ~= nil)
consumer:disable()
assert(first.dead and second.dead and not first.pressed)
assert(up == 1 and leaves == 1 and #service:pointers() == 0 and not target.highlighted)
assert(not first:beginGrab(target, matrix()))
first:setButton(true, sink, target)
assert(down == 1)
assert(not pcall(function()
  service:newPointer(owner)
end))
consumer:enable()
local otherOwner
local survivor = runtime:use(
  plugin.define(function(v)
    return v
  end, { interaction = contract.capability }, {}, function(ctx)
    otherOwner = ctx
  end),
  {}
)
survivor:enable()
local failedReleases = 0
local brokenSink = { dead = false }
function brokenSink:button(_, pressed)
  if not pressed then
    failedReleases += 1
    error 'native button release failed'
  end
end
local broken = service:newPointer(owner)
broken:setButton(true, brokenSink)
assert(not pcall(function()
  broken:destroy()
end))
assert(failedReleases == 1 and not broken:destroy())
assert(not pcall(function()
  service:newPointer(otherOwner)
end), 'provider must be quarantined')
runtime:close()
