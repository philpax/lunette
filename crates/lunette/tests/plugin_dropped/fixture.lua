local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'

local runtime = plugin.runtime()
local panelProvider = runtime:use(require '@lunette-plugins/panels', {})
panelProvider:enable()
local interactionProvider = runtime:use(require '@lunette-plugins/interaction', {})
interactionProvider:enable()

local panelService, interactionService, owner
local consumer = runtime:use(
  plugin.define {
    name = 'fixture-1',
    requires = { panels = panels.capability, interaction = interaction.capability },
    init = function(context)
      panelService, interactionService, owner =
        context:require(panels.capability), context:require(interaction.capability), context
    end,
  },
  {}
)
consumer:enable()

local events = {}
local function source(id)
  local result = { id = id, dead = false, width = 800, height = 600, title = 'Dropped test' }
  function result:getTexture()
    return false
  end
  function result:setProperty(key, value)
    assert(key == interactionService.POSE_PROPERTY)
    self.saved = value
    self.propertyOrder = #events
    events[#events + 1] = 'store'
    return true
  end
  return result
end

local firstSource, secondSource = source(1), source(2)
local first = panelService:fromWindow(owner, firstSource, { chrome = false })
local second = panelService:fromWindow(owner, secondSource, { chrome = false })
local pointer = interactionService:newPointer(owner)
local seen = {}
local allEffect = panelService:onDropped(owner, nil, function(panel, actualPointer)
  assert(actualPointer == pointer)
  seen[#seen + 1] = panel
  events[#events + 1] = panel == first and 'first' or 'second'
end)
local firstEffect = panelService:onDropped(owner, first, function(panel)
  assert(panel == first)
  events[#events + 1] = 'exact'
end)

panelService:emitDropped(owner, first, pointer)
assert(#seen == 1 and seen[1] == first)
assert(events[1] == 'first' and events[2] == 'exact')
allEffect:dispose()
panelService:emitDropped(owner, second, pointer)
assert(#seen == 1)
firstEffect:dispose()
panelService:emitDropped(owner, first, pointer)
assert(#events == 2)

local stale = owner
consumer:disable()
assert(not pcall(function()
  panelService:emitDropped(stale, first, pointer)
end))

local activeOwner, activePanel, activePointer
local activeConsumer = runtime:use(
  plugin.define {
    name = 'fixture-2',
    requires = { panels = panels.capability, interaction = interaction.capability },
    init = function(context)
      local panelService = context:require(panels.capability)
      local interactionService = context:require(interaction.capability)
      activeOwner, activePanel, activePointer =
        context, panelService:fromWindow(context, source(3), { chrome = false }), interactionService:newPointer(context)
    end,
  },
  {}
)
activeConsumer:enable()
local order = {}
local listener = activePanel
  and panelService:onDropped(activeOwner, activePanel, function()
    order[#order + 1] = 'drop'
  end)
activePanel:setPose(lovr.math.newMat4 { x = 2 })
activePanel.source.setProperty = function(self, key, value)
  order[#order + 1] = 'store'
  self.saved = value
  return true
end
assert(activePointer:beginGrab(activePanel, lovr.math.newMat4()))
assert(activePointer:endGrab())
assert(order[1] == 'drop' and order[2] == 'store')
listener:dispose()

local canceledCalls = 0
local canceled
local cancelFirst = panelService:onDropped(activeOwner, nil, function()
  canceled:dispose()
end)
canceled = panelService:onDropped(activeOwner, nil, function()
  canceledCalls += 1
end)
panelService:emitDropped(activeOwner, activePanel, activePointer)
assert(canceledCalls == 0, 'a canceled listener in the dispatch snapshot must be skipped')
cancelFirst:dispose()

local failing = panelService:onDropped(activeOwner, nil, function()
  error 'dropped callback failure'
end)
local ok, failure = pcall(function()
  panelService:emitDropped(activeOwner, activePanel, activePointer)
end)
assert(not ok and string.find(tostring(failure), 'dropped callback failure', 1, true))
failing:dispose()

local unloadingCalls = 0
local unloadingOwner
local unloading = runtime:use(
  plugin.define {
    name = 'fixture-3',
    requires = { panels = panels.capability },
    init = function(context)
      unloadingOwner = context
    end,
  },
  {}
)
unloading:enable()
panelService:onDropped(unloadingOwner, nil, function()
  unloadingCalls += 1
end)
unloadingOwner:effect(function()
  return function()
    panelService:emitDropped(activeOwner, activePanel, activePointer)
  end
end)
unloading:disable()
assert(unloadingCalls == 0, 'unloading suppresses callbacks before their inverse runs')

local weak = setmetatable({}, { __mode = 'v' })
local heldEffects = {}
for index = 1, 32 do
  do
    local payload = { index = index }
    weak[index] = payload
    local effect = panelService:onDropped(activeOwner, nil, function()
      assert(payload.index == index)
    end)
    heldEffects[index] = effect
    effect:dispose()
  end
  collectResources()
  collectResources()
  assert(weak[index] == nil, 'disposed listener effect retained its callback capture')
end

activeConsumer:disable()
interactionProvider:disable()
panelProvider:disable()
assert(not pcall(function()
  panelService:onDropped(activeOwner, nil, function() end)
end), 'stale provider must reject registration')
runtime:close()
