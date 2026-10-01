local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'
local rules = require '@lunette-contracts/rules'
local interaction = require '@lunette-contracts/interaction'
local adoption = require '@lunette-contracts/adoption'

local runtime = plugin.runtime()
local panelProvider = runtime:use(require '@lunette-plugins/panels', {})
local tagProvider = runtime:use(require '@lunette-plugins/tags', {})
local rulesProvider = runtime:use(require '@lunette-plugins/rules', {})
local interactionProvider = runtime:use(require '@lunette-plugins/interaction', {})
local adoptionProvider = runtime:use(require '@lunette-plugins/adoption', {})
panelProvider:enable()
tagProvider:enable()
rulesProvider:enable()
interactionProvider:enable()
adoptionProvider:enable()

local services
local owner
local consumer = runtime:use(
  plugin.define {
    name = 'adoption-1',
    requires = {
      panels = panels.capability,
      tags = tags.capability,
      rules = rules.capability,
      interaction = interaction.capability,
      adoption = adoption.capability,
    },
    init = function(context)
      services = {
        panels = context:require(panels.capability),
        tags = context:require(tags.capability),
        rules = context:require(rules.capability),
        interaction = context:require(interaction.capability),
        adoption = context:require(adoption.capability),
      }
      owner = context
    end,
  },
  {}
)
consumer:enable()

local result = {
  services = services,
  owner = owner,
  runtime = runtime,
  provider = adoptionProvider,
}

local function window(id, pose)
  local target = {
    id = id,
    dead = false,
    width = 800,
    height = 600,
    title = 'window-' .. id,
    appId = 'fixture.app',
    opaque = false,
    contentType = 'none',
    stored = {},
    closeCalls = 0,
  }
  target.sink = { dead = false }
  function target:getTexture()
    return false
  end
  function target:close()
    self.closeCalls += 1
    return true
  end
  function target:setProperty(key, value)
    if self.dead then
      return false
    end
    self.stored[key] = value
    return true
  end
  function target:getProperty(key)
    return self.stored[key]
  end
  function target:properties()
    return table.clone(self.stored)
  end
  if pose then
    target.stored[services.interaction.POSE_PROPERTY] = pose
  end
  return target
end

local windows = {}
local enumerateCalls = 0
local enumerateWhileSubscribed = false
local callbacks = {}
local subscribeCalls = 0
local unsubscribeCalls = 0
local callbackCalls = 0
local subscriptionReady = false
local closed = {}

local native = require '@lunette'
native.windows = function()
  enumerateCalls += 1
  enumerateWhileSubscribed = subscriptionReady
  return table.clone(windows)
end
native.onWindowOpened = function(handler)
  subscribeCalls += 1
  subscriptionReady = true
  local entry = { handler = handler, active = true }
  callbacks[#callbacks + 1] = entry
  return function()
    if entry.active then
      entry.active = false
      unsubscribeCalls += 1
    end
    subscriptionReady = false
  end
end

local function emit(target)
  for _, entry in ipairs(callbacks) do
    if entry.active then
      callbackCalls += 1
      entry.handler { window = target }
    end
  end
end

local function pose(x)
  local values = {}
  for index = 1, 16 do
    values[index] = if index == 13 then x elseif index == 1 or index == 6 or index == 11 or index == 16 then 1 else 0
  end
  return table.concat(values, ' ')
end

local low = services.rules:addSource(owner, {
  name = 'caller.rules',
  precedence = 100,
  resolve = function()
    return { title = 'rule-title', pose = pose(1) }
  end,
})
local persisted = services.rules:addSource(owner, {
  name = 'persistence',
  precedence = 200,
  resolve = function()
    return { title = 'persisted-title', pose = pose(2) }
  end,
})
local replaced = services.adoption:install(owner)
local sources = services.rules:sources()
assert(sources[1].name == 'caller.rules' and sources[1].precedence == 100)
assert(sources[2].name == 'persistence' and sources[2].precedence == 200)
assert(sources[3].name == services.adoption.SOURCE and sources[3].precedence == 300)
assert(enumerateCalls == 0, 'install must not enumerate native windows')

local saved = window(1, pose(3))
local ordinary = window(2)
windows = { saved, ordinary }
local placed = {}
local started = services.adoption:start(owner, {
  onPlaced = function(panel, resolved)
    placed[#placed + 1] = { panel = panel, resolved = resolved }
  end,
})
assert(subscribeCalls == 1 and enumerateCalls == 1 and enumerateWhileSubscribed)
assert(#placed == 2)
assert(placed[1].resolved.title == 'persisted-title')
assert(placed[1].resolved.pose == saved.stored[services.interaction.POSE_PROPERTY])
assert(placed[2].resolved.title == 'persisted-title')
assert(#services.panels:all() == 2)
assert(saved.closeCalls == 0 and ordinary.closeCalls == 0)

emit(saved)
assert(callbackCalls == 1 and #placed == 2, 'an existing panel must not be adopted twice')
local arriving = window(3)
emit(arriving)
assert(#placed == 3 and #services.panels:all() == 3)
assert(arriving.closeCalls == 0)

started:dispose()
assert(unsubscribeCalls == 1)
assert(#services.panels:all() == 0, 'disposing the start releases its panels')
local stale = window(4)
emit(stale)
assert(#services.panels:all() == 0 and #placed == 3, 'a stale callback must be inert')

windows = { saved, ordinary, arriving }
local secondStart = services.adoption:start(owner)
assert(subscribeCalls == 2 and enumerateCalls == 2 and enumerateWhileSubscribed)
assert(#services.panels:all() == 3 and #placed == 3, 'reactivation enumerates survivors once')
local secondArriving = window(5)
emit(secondArriving)
assert(#services.panels:all() == 4 and #placed == 3, 'replacement event must place once')

secondStart:dispose()
assert(unsubscribeCalls == 2)
assert(#services.panels:all() == 0)
assert(
  saved.closeCalls == 0 and ordinary.closeCalls == 0 and arriving.closeCalls == 0 and secondArriving.closeCalls == 0
)

local sourceCallback = services.adoption:source()
assert(sourceCallback(saved).pose == saved.stored[services.interaction.POSE_PROPERTY])
replaced:dispose()
persisted:dispose()
low:dispose()

function result.failInitialization()
  windows = { window(101), window(102) }
  local claimsBefore = #claims
  local placements = 0
  local failedOwner
  local failed = runtime:use(
    plugin.define {
      name = 'adoption-2',
      requires = { adoption = adoption.capability },
      init = function(context)
        failedOwner = context
        local service = context:require(adoption.capability)
        service:start(context, {
          onPlaced = function()
            placements += 1
            if placements == 2 then
              error 'fixture: onPlaced failure'
            end
          end,
        })
      end,
    },
    {}
  )
  failed:enable()
  local copied = callbacks[#callbacks].handler
  assert(not failedOwner:active(), 'the throwing consumer must fail initialization')
  assert(#services.panels:all() == 0, 'failed initialization must release every adopted panel')
  assert(subscribeCalls == unsubscribeCalls, 'failed initialization must unsubscribe')
  assert(#claims == claimsBefore + 2)
  for index = claimsBefore + 1, #claims do
    assert(claims[index].dead, 'failed initialization must release native claims')
  end
  local delivered = callbackCalls
  local later = window(103)
  emit(later)
  copied { window = later }
  assert(callbackCalls == delivered and placements == 2, 'failed caller callbacks must be inert')
  assert(not services.panels:forSource(later))
  for _, target in ipairs(windows) do
    assert(target.closeCalls == 0, 'adoption must not close borrowed windows')
  end
  assert(later.closeCalls == 0)
end

function result.failEnumeration()
  local enumerate = native.windows
  native.windows = function()
    error 'fixture: enumeration failure'
  end
  local ok, failure = pcall(function()
    services.adoption:start(owner)
  end)
  native.windows = enumerate
  assert(not ok and string.find(tostring(failure), 'fixture: enumeration failure', 1, true))
  assert(subscribeCalls == unsubscribeCalls, 'caught enumeration failure must unsubscribe immediately')
  local copied = callbacks[#callbacks].handler
  local later = window(104)
  copied { window = later }
  assert(not services.panels:forSource(later), 'copied failed-start callback must be inert')
  windows = { later }
  local retry = services.adoption:start(owner)
  assert(services.panels:forSource(later), 'enumeration failure must allow a clean retry')
  retry:dispose()
  assert(#services.panels:all() == 0 and later.closeCalls == 0)
  assert(subscribeCalls == unsubscribeCalls)
end

function result.cancelCaller()
  windows = { window(201) }
  local placements = 0
  local caller
  local cancelDuringEnumeration = false
  local enumerate = native.windows
  native.windows = function()
    local existing = enumerate()
    if cancelDuringEnumeration then
      caller:disable()
      callbacks[#callbacks].handler { window = window(203) }
    end
    return existing
  end
  caller = runtime:use(
    plugin.define {
      name = 'adoption-3',
      requires = { adoption = adoption.capability },
      init = function(context)
        context:require(adoption.capability):start(context, {
          onPlaced = function()
            placements += 1
          end,
        })
      end,
    },
    {}
  )
  caller:enable()
  assert(placements == 1 and #services.panels:all() == 1)
  local copied = callbacks[#callbacks].handler
  caller:disable()
  copied { window = window(202) }
  assert(#services.panels:all() == 0 and placements == 1, 'disabled caller callbacks must be inert')
  cancelDuringEnumeration = true
  caller:enable()
  assert(placements == 1 and #services.panels:all() == 0, 'cancelled enumeration must not place windows')
  assert(subscribeCalls == unsubscribeCalls, 'caller cancellation must unsubscribe')
  assert(windows[1].closeCalls == 0)
end

-- A caller that requires adoption alone installs the native-state source. The
-- registration belongs to the caller's lifetime but not to its rules binding.
function result.installWithoutRules()
  local function registered(): boolean
    for _, source in services.rules:sources() do
      if source.name == services.adoption.SOURCE and source.precedence == 250 then
        return true
      end
    end
    return false
  end
  local installer = runtime:use(
    plugin.define {
      name = 'adoption-4',
      requires = { adoption = adoption.capability },
      init = function(context)
        context:require(adoption.capability):install(context, { precedence = 250 })
      end,
    },
    {}
  )
  installer:enable()
  assert(installer:state() == 'active', tostring(installer:diagnostic()))
  assert(registered(), 'install must register the source without the caller requiring rules')
  installer:disable()
  assert(not registered(), 'the source must end with the caller that installed it')
end

function result.releaseNativeCallbacks()
  table.clear(callbacks)
end

local retainedSources = setmetatable({}, { __mode = 'v' })
local retainedSerial = 0

function result.placementLifetime(payload, mode)
  retainedSerial += 1
  local target = window(400 + retainedSerial)
  target.payload = payload
  retainedSources[retainedSerial] = target
  windows = { target }
  local claimsBefore = #claims
  local defaults = { tags = { 'temporary-adoption-tag', 'existing-adoption-tag' } }
  local existing = services.tags:find 'existing-adoption-tag' or services.tags:new(owner, 'existing-adoption-tag')
  local placedCalls = 0
  local options = {
    defaults = defaults,
    onPlaced = function()
      placedCalls += 1
      if mode ~= 'dispose' and mode ~= 'disable' then
        error 'fixture: placement lifetime failure'
      end
    end,
  }
  if mode == 'failed-consumer' or mode == 'disable' then
    local caller = runtime:use(
      plugin.define {
        name = 'adoption-5',
        requires = { adoption = adoption.capability },
        init = function(context)
          context:require(adoption.capability):start(context, options)
        end,
      },
      {}
    )
    caller:enable()
    if mode == 'disable' then
      caller:disable()
    end
    caller:dispose()
  elseif mode == 'caught' then
    local ok, failure = pcall(function()
      services.adoption:start(owner, options)
    end)
    assert(not ok and string.find(tostring(failure), 'fixture: placement lifetime failure', 1, true))
  else
    local started = services.adoption:start(owner, options)
    assert(services.tags:find 'temporary-adoption-tag', 'placement must acquire its implicit tag')
    started:dispose()
  end
  assert(placedCalls == 1)
  assert(#services.panels:all() == 0 and not services.panels:forSource(target))
  assert(#claims == claimsBefore + 1 and claims[#claims].dead)
  assert(subscribeCalls == unsubscribeCalls)
  assert(not services.tags:find 'temporary-adoption-tag', 'caller cleanup must destroy newly created placement tags')
  assert(services.tags:find 'existing-adoption-tag' == existing and not existing.dead)
  assert(#existing:panels() == 0, 'caller cleanup must remove membership without destroying existing tags')
  assert(target.closeCalls == 0)
  windows = {}
  local copied = callbacks[#callbacks].handler
  local callsBefore = callbackCalls
  emit(window(900 + retainedSerial))
  copied { window = window(1000 + retainedSerial) }
  assert(placedCalls == 1 and callbackCalls == callsBefore)
  assert(#services.panels:all() == 0)
end

function result.checkPlacementCollection()
  assert(owner:active(), 'observer and provider graph must remain active')
  assert(#services.rules:sources() == 0 and #services.panels:all() == 0)
  assert(services.adoption:properties(window(1100)) == nil, 'adoption must remain active')
  for index = 1, retainedSerial do
    assert(retainedSources[index] == nil, 'disposed rules placement must not retain its native source')
  end
end

return result
