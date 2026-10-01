local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local persist = require '@lunette-desktop/persist'

local original = persist.render(persist.newFile {
  {
    kind = 'window',
    key = 'fixture.app',
    slot = 1,
    pose = '1 0 0 0 0 1 0 0 0 0 1 0 0 0 -2 1',
    width = 2,
    height = 1,
    tags = { 'main' },
  },
  {
    kind = 'window',
    key = 'fixture.app',
    slot = 2,
    pose = '1 0 0 0 0 1 0 0 0 0 1 0 0 0 -3 1',
    width = 4,
    height = 2,
    tags = {},
  },
})
local filesystem = { text = original, writes = 0, reads = 0, writable = true }
function filesystem.read(filename)
  assert(filename == 'arrangement.state')
  filesystem.reads += 1
  return filesystem.text
end
function filesystem.write(filename, text)
  assert(filename == 'arrangement.state')
  if not filesystem.writable then
    return false
  end
  filesystem.writes += 1
  filesystem.text = text
  return true
end
function filesystem.getSaveDirectory()
  return '/test-save'
end
local reported = {}
local function report(message)
  reported[#reported + 1] = message
end
local runtime = plugin.runtime()
local panelsInstance = runtime:use(require('@lunette-plugins/panels').definition, {})
local tagsInstance = runtime:use(require('@lunette-plugins/tags').definition, {})
local rulesInstance = runtime:use(require('@lunette-plugins/rules').definition, {})
panelsInstance:enable()
tagsInstance:enable()
rulesInstance:enable()

local state = persist.new { filesystem = filesystem, report = report }
local loaded = state:loaded()
local binding, context, panels, tags, rules
local cleanupChecks = 0
local beforeCleanup
local function consumerDefinition(persistent)
  return plugin.define {
    name = 'runtime-1',
    requires = { panels = panelsContract.capability, tags = tagsContract.capability, rules = rulesContract.capability },
    init = function(current)
      context = current
      panels = current:require(panelsContract.capability)
      tags = current:require(tagsContract.capability)
      rules = current:require(rulesContract.capability)
      local bound, result = pcall(function()
        return persistent:bind(current, panels, tags, rules)
      end)
      if not bound then
        reported[#reported + 1] = tostring(result)
        error(result)
      end
      binding = result
      rules:setRules(current, { rules = { { properties = { width = 1 } } } })
      local currentBinding = binding
      local currentPanels = panels
      local currentRules = rules
      current:effect(function()
        return function()
          cleanupChecks += 1
          assert(not current:active(), 'context becomes inactive before inverse cleanup')
          assert(not currentBinding:active(), 'saves suspend before the binding inverse runs')
          assert(not currentBinding:save { force = true }, 'force cannot save an unloading scope')
          if beforeCleanup then
            beforeCleanup(currentBinding, currentPanels, currentRules)
          end
        end
      end)
    end,
  }
end
local owner = runtime:use(consumerDefinition(state), {})
owner:enable()
assert(context:active() and binding ~= nil, 'consumer initialization must complete: ' .. table.concat(reported, '\n'))
local function window(id)
  return { id = id, dead = false, appId = 'fixture.app', width = 800, height = 600, opaque = false }
end
local first = window(17)
local second = window(18)
local nativeEffect = rules:addSource(context, {
  name = 'fixture.native',
  precedence = 300,
  resolve = function()
    return { width = 3 }
  end,
})
assert(rules:resolve(first).width == 3, 'native source at 300 wins')
nativeEffect:dispose()
assert(rules:resolve(first).width == 2, 'persisted source at 200 wins over rules at 100')
assert(rules:resolve(second).width == 2, 'resolving is a query: a window takes no slot until its panel exists')
local firstPanel = panels:fromWindow(context, first)
assert(rules:resolve(first).width == 2, 'a window holds its slot once its panel exists')
assert(rules:resolve(second).width == 4, 'the next window answers the next free slot')
local sourceList = rules:sources()
assert(#sourceList == 2)
assert(sourceList[1].precedence == 100 and sourceList[2].name == persist.SOURCE and sourceList[2].precedence == 200)
local firstBinding = binding
local oldPanels, oldTags, oldRules = panels, tags, rules
local weakServices = setmetatable({ panels, rules }, { __mode = 'v' })

-- No save precedes the outage, so rebind must retain the initially loaded file.
filesystem.text = 'return { version = 99, entries = {} }'
panelsInstance:disable()
assert(not firstBinding:active() and not firstBinding:save { force = true })
assert(filesystem.writes == 0 and filesystem.reads == 1)
assert(state:loaded() == loaded and #persist.entries(state:arrangement()) == 2)
assert(not pcall(function()
  oldPanels:all()
end), 'old provider is retired')
assert(not pcall(function()
  oldRules:sources()
end), 'old rules service is retired')
panelsInstance:enable()
assert(binding ~= firstBinding and binding:active(), 'consumer rebinds automatically')
assert(firstPanel.dead, 'the outage removed the panel')
assert(panels ~= oldPanels and tags == oldTags and rules ~= oldRules, 'tags does not depend on panels')
assert(rules:resolve(first).width == 2, 'a live window keeps its slot across a provider outage')
assert(rules:resolve(second).width == 4, 'and another window does not take it')
-- A window that closes frees its slot, and a window that opens takes it.
first.dead = true
local reopened = window(23)
assert(rules:resolve(reopened).width == 2, 'a reopened window answers the slot the closed one left')
panels:fromWindow(context, reopened):destroy(context)
assert(rules:resolve(second).width == 4, 'the reopened window holds that slot')
second.dead = true
reopened.dead = true
assert(filesystem.reads == 1 and state:declined() == nil, 'activation never reloads the file')
oldPanels, oldTags, oldRules = nil, nil, nil
collectgarbage 'collect'
collectgarbage 'collect'
assert(weakServices[1] == nil and weakServices[2] == nil, 'state and old binding release services')

local target = panels:fromWindow(context, window(19), { width = 1.5 })
tags:new(context, 'saved'):add(context, target)
assert(binding:save())
assert(filesystem.writes == 1, 'an active binding saves live panels')
local captured = state:arrangement()
assert(persist.entries(captured)[1].width == 1.5)
assert(persist.entries(captured)[1].tags[1] == 'saved')
local afterSave = window(22)
assert(rules:resolve(target.source).width == 1.5, 'the source reads the arrangement the save wrote')
assert(rules:resolve(afterSave).width == 1, 'the saved window holds the only saved slot')
assert(rules:resolve(afterSave).width == 1, 'repeated lookups do not change the answer')
beforeCleanup = function(currentBinding, _currentPanels, currentRules)
  assert(#currentRules:sources() == 2, 'persistence source inverse has not run yet')
  assert(not currentBinding:save(), 'ordinary cleanup save is refused')
  assert(filesystem.writes == 1, 'unload-time saves write nothing')
end
owner:disable()
assert(filesystem.writes == 1 and not binding:active())
assert(#rules:sources() == 0, 'binding and caller rules are removed exactly')
beforeCleanup = nil
owner:enable()
assert(state:arrangement() == captured and filesystem.reads == 1)
target.source.dead = true
assert(rules:resolve(window(20)).width == 1.5, 'successful save becomes the next activation arrangement')
local liveBinding = binding
binding:dispose()
binding:dispose()
assert(not liveBinding:active() and not liveBinding:save { force = true })
assert(#rules:sources() == 1, 'dispose removes only persistence source')
owner:disable()

for _, text in ipairs { 'return { version = 99, entries = {}, future = true }', 'return {' } do
  filesystem.text = text
  local refusedState = persist.new { filesystem = filesystem, report = report }
  local refusedOwner = runtime:use(consumerDefinition(refusedState), {})
  refusedOwner:enable()
  local refusal = refusedState:declined()
  assert(refusal ~= nil)
  local reads, writes = filesystem.reads, filesystem.writes
  assert(not binding:save() and filesystem.text == text)
  panelsInstance:disable()
  filesystem.text = nil
  panelsInstance:enable()
  assert(refusedState:declined() == refusal and filesystem.reads == reads, 'refusal survives outage without rereading')
  assert(not binding:save() and filesystem.writes == writes)
  filesystem.writable = false
  assert(not binding:save { force = true } and refusedState:declined() == refusal, 'failed force preserves refusal')
  filesystem.writable = true
  assert(binding:save { force = true } and refusedState:declined() == nil, 'successful force clears refusal')
  assert(binding:save() and filesystem.writes == writes + 2)
  refusedOwner:disable()
  assert(filesystem.writes == writes + 2, 'unload never saves')
end
runtime:close()
assert(cleanupChecks >= 7, 'cleanup assertions must have executed')
persistenceRuntimeVerified = true
