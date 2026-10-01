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
local vectorMeta = {}
vectorMeta.__index = {
  length = function(self)
    return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2)
  end,
  unpack = function(self)
    return self.x, self.y, self.z
  end,
}
function vectorMeta.__mul(value, scale)
  return setmetatable({ x = value.x * scale, y = value.y * scale, z = value.z * scale }, vectorMeta)
end
vector = {
  pack = function(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, vectorMeta)
  end,
}
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/interaction'
local focusContract = require '@lunette-contracts/focus'
local interactionModule = require '@lunette-plugins/interaction'
local runtime = plugin.runtime()
runtime:use(require('@lunette-plugins/drops').definition, {}):enable()
local focusProvider = runtime:use(require('@lunette-plugins/focus').definition, {})
focusProvider:enable()
local provider = runtime:use(interactionModule.definition, {})
provider:enable()
local service, focus, owner
local consumer = runtime:use(
  plugin.define {
    name = 'runtime-1',
    requires = { interaction = contract.capability, focus = focusContract.capability },
    init = function(ctx)
      service, focus, owner = ctx:require(contract.capability), ctx:require(focusContract.capability), ctx
    end,
  },
  {}
)
consumer:enable()
local wrongOwner = runtime:use(
  plugin.define {
    name = 'runtime-2',
    init = function(ctx)
      assert(not pcall(function()
        service:newPointer(ctx)
      end))
    end,
  },
  {}
)
wrongOwner:enable()
assert(#service:pointers() == 0)
local weakResources = setmetatable({}, { __mode = 'v' })
for _ = 1, 12 do
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
local pressed, released, leaves = {}, {}, 0
local seat = {
  dead = false,
  setFocus = function(self, sink)
    self.focus = sink
  end,
}
local sink = { dead = false }
function sink:button(button, isDown, actualSeat)
  assert(actualSeat == seat)
  local list = isDown and pressed or released
  list[#list + 1] = button
end
function sink:leave(actualSeat)
  assert(actualSeat == seat)
  leaves += 1
end
function sink:pointer(x, y, actualSeat)
  assert(actualSeat == seat)
  self.at = { x, y }
end
function sink:scroll() end
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

-- A pointer answers what it hovers and carries, and nothing it does not
-- expose; it cannot be assigned.
assert(first.seat == seat and first.dead == false and first.tuning.reach == service.TUNING.reach)
assert(first.grab == nil and first.scaling == nil and first.pressed == nil and first.handPosition == nil)
assert(not pcall(function()
  first.hovered = target
end), 'a pointer is read-only')
-- A pointer's own tuning merges over the provider's.
local near = service:newPointer(owner, { tuning = { reach = 1 } })
assert(near.tuning.reach == 1 and near.tuning.scrollScale == service.TUNING.scrollScale)
near:destroy()

-- A surface two pointers hover stays highlighted until both have left.
local shared = { dead = false }
function shared:setHighlighted(value)
  self.highlighted = value
end
first:hover(shared)
second:hover(shared)
first:hover(nil)
assert(shared.highlighted, 'another pointer still hovers the surface')
second:hover(nil)
assert(not shared.highlighted, 'the last pointer to leave clears the highlight')
first:hover(target)
assert(first.hovered == target and target.highlighted)

-- A press of a sink presses its button and, by default, gives the seat's
-- keyboard to it through the focus contract.
first:setButton { pressed = true, sink = sink, surface = target }
assert(pressed[1] == 'left' and seat.focus == sink)
assert(focus:focused() == seat)
first:setButton { button = 'right', pressed = true, sink = sink, surface = target }
first:setButton { button = 'right', pressed = false }
assert(pressed[2] == 'right' and released[1] == 'right', 'each pointer button is its own press')
assert(not pcall(function()
  first:setButton { button = 'thumb', pressed = true }
end), 'a button that is not a pointer button raises')

-- Grabbing, pushing, dragging, and two-handed scaling move and size the
-- surface.
assert(first:beginGrab(target, matrix()))
assert(first.grabbed == target)
first:push { deflection = 1, dt = 1 }
first:dragTo(matrix { x = 1 })
assert(target.pose.x == 1 and target.pose.z < -2, 'the push moves the surface along the ray')
first:dragTo(matrix())
assert(target.pose.x == 0)
assert(second:beginGrab(target, matrix { x = 1 }))
second:scaleWith(matrix { x = 2 })
assert(target.width == 2)
assert(first:endGrab(), 'ending a grab answers that something was carried')
assert(first.grabbed == nil)
second:scaleWith(matrix { x = 2 })
second:dragTo(matrix { x = 5 })
assert(target.pose.x == 3, 'the partner that let go turns a scale into an ordinary grab')
assert(second:endGrab())
consumer:disable()
assert(seat.focus == nil, 'a destroyed pointer withdraws the native focus it gave')
assert(focus:focused() == nil, 'a destroyed pointer is no longer answered as focused')
assert(first.dead and second.dead)
assert(released[2] == 'left' and leaves == 1 and #service:pointers() == 0 and not target.highlighted)
assert(not first:beginGrab(target, matrix()))
first:setButton { pressed = true, sink = sink, surface = target }
assert(#pressed == 2)
assert(not pcall(function()
  service:newPointer(owner)
end))
consumer:enable()

-- update maps input onto the primitives: buttons press, a grip grabs.
local input = function(fields)
  return {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = fields.pose or matrix(),
    buttons = fields.buttons or {},
    grip = fields.grip or false,
    dt = 0.016,
  }
end
local plate = {
  dead = false,
  pose = matrix { z = -1 },
  width = 1,
  height = 1,
  raycast = function()
    return 10, 20, 1
  end,
  sink = function()
    return sink
  end,
  setPose = function(self, value)
    self.pose:set(value)
  end,
}
local driven = service:newPointer(owner, { seat = seat })
table.clear(pressed)
driven:update(input { buttons = { left = true, middle = true } }, { plate })
assert(driven.hovered == plate and driven.hitX == 10 and driven.distance == 1)
assert(pressed[1] == 'left' and pressed[2] == 'middle' and #pressed == 2)
driven:update(input {}, { plate })
driven:update(input { grip = true }, { plate })
assert(driven.grabbed == plate)
driven:update(input {}, { plate })
assert(driven.grabbed == nil, 'releasing the grip drops the surface')
driven:destroy()
runtime:close()

-- Hooks: a drive hook that remaps buttons, a constraint that keeps a carried
-- surface at one height, and no focus on press.
runtime = plugin.runtime()
runtime:use(require('@lunette-plugins/drops').definition, {}):enable()
runtime:use(require('@lunette-plugins/focus').definition, {}):enable()
local remapped = 0
local hooked = interactionModule.define {
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
  constrain = function(surface, pose, base)
    local constrained = base(surface, pose)
    constrained.y = 1.5
    return constrained
  end,
}
runtime:use(hooked, {}):enable()
consumer = runtime:use(
  plugin.define {
    name = 'runtime-4',
    requires = { interaction = contract.capability, focus = focusContract.capability },
    init = function(ctx)
      service, focus, owner = ctx:require(contract.capability), ctx:require(focusContract.capability), ctx
    end,
  },
  {}
)
consumer:enable()
seat.focus = nil
table.clear(pressed)
local hookedPointer = service:newPointer(owner, { seat = seat })
hookedPointer:update(input { buttons = { left = true } }, { plate })
assert(remapped == 1 and pressed[1] == 'right' and #pressed == 1, 'the drive hook remapped the trigger')
assert(seat.focus == nil and focus:focused() == nil, 'focusOnPress = false gives no focus on a press')
hookedPointer:update(input {}, { plate })
plate.pose:set(matrix { z = -1 })
hookedPointer:update(input { grip = true }, { plate })
assert(hookedPointer.grabbed == plate)
hookedPointer:update(input { grip = true, pose = matrix { x = 2, y = 4 } }, { plate })
assert(plate.pose.x == 2 and plate.pose.y == 1.5, 'the constraint kept the height and allowed the slide')
hookedPointer:update(input {}, { plate })
assert(not pcall(function()
  interactionModule.define { drive = 'not a hook' }
end), 'a hook is a function')
runtime:close()
runtime = plugin.runtime()
runtime:use(require('@lunette-plugins/drops').definition, {}):enable()
runtime:use(require('@lunette-plugins/focus').definition, {}):enable()
provider = runtime:use(interactionModule.definition, {})
provider:enable()
consumer = runtime:use(
  plugin.define {
    name = 'runtime-5',
    requires = { interaction = contract.capability },
    init = function(ctx)
      service, owner = ctx:require(contract.capability), ctx
    end,
  },
  {}
)
consumer:enable()

local otherOwner
local survivor = runtime:use(
  plugin.define {
    name = 'runtime-3',
    requires = { interaction = contract.capability },
    init = function(ctx)
      otherOwner = ctx
    end,
  },
  {}
)
survivor:enable()
local failedReleases = 0
local brokenSink = { dead = false }
function brokenSink:button(_, isDown)
  if not isDown then
    failedReleases += 1
    error 'native button release failed'
  end
end
local broken = service:newPointer(owner)
broken:setButton { pressed = true, sink = brokenSink }
assert(not pcall(function()
  broken:destroy()
end), 'a direct destroy raises its release failure to its caller')
assert(failedReleases == 1 and not broken:destroy())
assert(service:newPointer(otherOwner), 'the provider still serves after a consumer release failed')
-- A release that fails while its owner unloads is that owner's failure.
local leaking = service:newPointer(owner)
leaking:setButton { pressed = true, sink = brokenSink }
consumer:disable()
assert(failedReleases == 2 and leaking.dead)
assert(consumer:state() == 'quarantined', 'the failing owner is quarantined: ' .. consumer:state())
assert(provider:state() == 'active', 'the provider is not quarantined: ' .. provider:state())
assert(service:newPointer(otherOwner))
runtime:close()
