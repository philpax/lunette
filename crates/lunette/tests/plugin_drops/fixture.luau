-- The drops broker, and interaction emitting through it.
local native = require '@lunette'
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local interaction = require '@lunette-contracts/interaction'

local reported = {}
native.reportError = function(fields)
  reported[#reported + 1] = fields.context .. ': ' .. fields.message
end

local runtime = plugin.runtime()
local dropProvider = runtime:use(require('@lunette-plugins/drops').definition, {})
dropProvider:enable()
local focusProvider = runtime:use(require('@lunette-plugins/focus').definition, {})
focusProvider:enable()
local interactionProvider = runtime:use(require('@lunette-plugins/interaction').definition, {})
interactionProvider:enable()

local dropService, interactionService, owner
local consumer = runtime:use(
  plugin.define {
    name = 'fixture-1',
    requires = { drops = drops.capability, interaction = interaction.capability },
    init = function(context)
      dropService, interactionService, owner =
        context:require(drops.capability), context:require(interaction.capability), context
    end,
  },
  {}
)
consumer:enable()

local function surface(x)
  local result = { dead = false, pose = lovr.math.newMat4 { x = x or 0 }, width = 1, height = 1 }
  function result:setPose(pose)
    self.pose:set(pose)
  end
  function result:raycast()
    return nil, nil, nil
  end
  return result
end

-- Listeners hear every drop in registration order, and a disposed listener
-- hears none.
local first, second = surface(), surface()
local pointer = interactionService:newPointer(owner)
local events = {}
local allEffect = dropService:onDropped(owner, {
  run = function(drop)
    assert(drop.pointer == pointer)
    events[#events + 1] = drop.surface == first and 'first' or 'second'
  end,
})
local laterEffect = dropService:onDropped(owner, {
  run = function()
    events[#events + 1] = 'later'
  end,
})
dropService:emit(owner, { surface = first, pointer = pointer })
assert(events[1] == 'first' and events[2] == 'later' and #events == 2)
allEffect:dispose()
dropService:emit(owner, { surface = second, pointer = pointer })
assert(#events == 3 and events[3] == 'later')
laterEffect:dispose()
dropService:emit(owner, { surface = first, pointer = pointer })
assert(#events == 3)

-- Malformed calls raise at the call.
assert(not pcall(function()
  dropService:onDropped(owner, { run = function() end, panel = first })
end), 'an unknown listener field raises')
assert(not pcall(function()
  dropService:onDropped(owner, { run = 'no' })
end), 'a run that is not a function raises')
assert(not pcall(function()
  dropService:emit(owner, { surface = first })
end), 'a drop without a pointer raises')
assert(not pcall(function()
  dropService:emit(owner, { surface = first, pointer = pointer, extra = true })
end), 'an unknown drop field raises')

-- A drop is emitted when a grab ends, while the pointer still names the
-- surface it carried.
local carried = surface()
local heard = {}
local grabbedListener = dropService:onDropped(owner, {
  run = function(drop)
    heard[#heard + 1] = drop
    assert(drop.pointer.grabbed == carried, 'the pointer still names what it let go of')
  end,
})
assert(pointer:beginGrab(carried, lovr.math.newMat4()))
assert(pointer:endGrab(), 'ending a grab answers that something was carried')
assert(#heard == 1 and heard[1].surface == carried and heard[1].pointer == pointer)
assert(pointer.grabbed == nil)
assert(not pointer:endGrab(), 'nothing is carried twice')
assert(#heard == 1)
assert(not pcall(function()
  heard[1].surface = first
end), 'a delivered drop is frozen')

-- A listener that raises is reported, and the listeners after it still run.
local after = 0
local failing = dropService:onDropped(owner, {
  run = function()
    error 'drop listener failure'
  end,
})
local following = dropService:onDropped(owner, {
  run = function()
    after += 1
  end,
})
assert(pointer:beginGrab(carried, lovr.math.newMat4()))
assert(pointer:endGrab())
assert(after == 1, 'the listener after a raising one runs')
assert(#reported == 1 and reported[1]:find('drop listener failure', 1, true), tostring(reported[1]))
failing:dispose()
following:dispose()
grabbedListener:dispose()

-- A listener disposed by an earlier listener of the same drop is skipped.
local canceledCalls = 0
local canceled
local cancelFirst = dropService:onDropped(owner, {
  run = function()
    canceled:dispose()
  end,
})
canceled = dropService:onDropped(owner, {
  run = function()
    canceledCalls += 1
  end,
})
dropService:emit(owner, { surface = first, pointer = pointer })
assert(canceledCalls == 0, 'a listener disposed during the dispatch is skipped')
cancelFirst:dispose()

-- An unloading owner's listeners are not called while its effects unwind.
local unloadingCalls = 0
local unloadingOwner
local unloading = runtime:use(
  plugin.define {
    name = 'fixture-2',
    requires = { drops = drops.capability },
    init = function(context)
      unloadingOwner = context
    end,
  },
  {}
)
unloading:enable()
dropService:onDropped(unloadingOwner, {
  run = function()
    unloadingCalls += 1
  end,
})
unloadingOwner:effect(function()
  return function()
    dropService:emit(owner, { surface = first, pointer = pointer })
  end
end)
unloading:disable()
assert(unloadingCalls == 0, 'unloading suppresses listeners before their inverse runs')

-- A stale owner cannot emit.
local stale = owner
consumer:disable()
assert(not pcall(function()
  dropService:emit(stale, { surface = first, pointer = pointer })
end), 'a stale owner cannot emit')
consumer:enable()

-- A disposed listener does not retain what it captured.
local weak = setmetatable({}, { __mode = 'v' })
for index = 1, 32 do
  do
    local payload = { index = index }
    weak[index] = payload
    local effect = dropService:onDropped(owner, {
      run = function()
        assert(payload.index == index)
      end,
    })
    effect:dispose()
  end
  collectResources()
  collectResources()
  assert(weak[index] == nil, 'a disposed listener retained its capture')
end

consumer:disable()
interactionProvider:disable()
dropProvider:disable()
assert(not pcall(function()
  dropService:onDropped(owner, { run = function() end })
end), 'a stale provider rejects registration')
runtime:close()
