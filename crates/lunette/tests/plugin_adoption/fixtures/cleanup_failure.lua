local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local rules = require '@lunette-contracts/rules'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'
local native = require '@lunette'

return function(fixture, payload, mode, extraFailure)
  local services = fixture.services
  local runtime = fixture.runtime
  local observer
  local independent = runtime:use(
    plugin.define(function(value)
      return value
    end, { panels = panels.capability, tags = tags.capability }, {}, function(context)
      observer = context
    end),
    {}
  )
  independent:enable()
  local calls = {}
  local order = {}
  local function record(name)
    calls[name] = (calls[name] or 0) + 1
    order[#order + 1] = name
  end
  local function window(id)
    return {
      id = id,
      dead = false,
      width = 800,
      height = 600,
      closeCalls = 0,
      appId = 'fixture.cleanup',
      getProperty = function() end,
      close = function(self)
        self.closeCalls += 1
      end,
    }
  end
  local unrelatedSource = window(1201)
  local unrelatedPanel = services.panels:fromWindow(observer, unrelatedSource)
  local unrelatedClaim = claims[#claims]
  local unrelatedTag = services.tags:new(observer, 'unrelated-cleanup-tag')
  unrelatedTag:add(unrelatedPanel)
  local ordinary = services.tags:new(observer, 'ordinary-cleanup-tag')
  local throwing = services.tags:new(observer, 'throwing-cleanup-tag')
  local ordinaryRemove = ordinary.remove
  ordinary.remove = function(self, panel)
    record 'ordinary.remove'
    return ordinaryRemove(self, panel)
  end
  local throwingRemove = throwing.remove
  throwing.remove = function(self, panel)
    record 'throwing.remove'
    throwingRemove(self, panel)
    error 'fixture: membership remove failure'
  end
  local source = window(1202)
  source.payload = payload
  local weak = setmetatable({ source }, { __mode = 'v' })
  local windows = { source }
  local subscriptions = 0
  local unsubscriptions = 0
  local subscribe = native.onWindowOpened
  native.windows = function()
    return table.clone(windows)
  end
  native.onWindowOpened = function(callback)
    subscriptions += 1
    local unsubscribe = subscribe(callback)
    return function()
      unsubscriptions += 1
      unsubscribe()
    end
  end
  local callerOwner
  local loads = 0
  local caller = runtime:use(
    plugin.define(
      function(value)
        return value
      end,
      if mode == 'direct' then { rules = rules.capability } else { adoption = adoption.capability },
      {},
      function(context)
        callerOwner = context
        loads += 1
      end
    ),
    {}
  )
  caller:enable()
  local panel
  local started
  local settings = { tags = { 'first-cleanup-implicit', 'second-cleanup-implicit', ordinary, throwing } }
  if mode == 'direct' then
    panel = services.rules:place(callerOwner, source, settings)
  else
    started = services.adoption:start(callerOwner, {
      defaults = settings,
      onPlaced = function(created)
        panel = created
      end,
    })
  end
  local claim = claims[#claims]
  local release = claim.release
  claim.release = function(self)
    record 'claim.release'
    return release(self)
  end
  for _, name in ipairs { 'first-cleanup-implicit', 'second-cleanup-implicit' } do
    local tag = assert(services.tags:find(name))
    local remove = tag.remove
    tag.remove = function(self, target)
      record(name .. '.remove')
      return remove(self, target)
    end
    local destroy = tag.destroy
    tag.destroy = function(self)
      record(name .. '.destroy')
      local result = destroy(self)
      if extraFailure and name == 'second-cleanup-implicit' then
        error 'fixture: implicit destroy failure'
      end
      return result
    end
  end
  local destroy = panel.destroy
  local testingCleanup = true
  panel.destroy = function(self)
    if testingCleanup and self.dead then
      record 'panel.cleanupDestroy'
    end
    return destroy(self)
  end
  local ok, failure = pcall(function()
    if mode == 'direct' then
      panel:destroy()
    else
      started:dispose()
    end
  end)
  testingCleanup = false
  assert(not ok and string.find(tostring(failure), 'fixture: membership remove failure', 1, true))
  if extraFailure then
    assert(
      string.find(tostring(failure), 'fixture: implicit destroy failure', 1, true),
      'cleanup errors must aggregate'
    )
  end
  assert(calls['throwing.remove'] == 1)
  assert(calls['ordinary.remove'] == 1, 'one throwing removal must not skip another membership')
  assert(calls['second-cleanup-implicit.remove'] == 1 and calls['first-cleanup-implicit.remove'] == 1)
  assert(calls['panel.cleanupDestroy'] == 1 and calls['claim.release'] == 1)
  assert(calls['second-cleanup-implicit.destroy'] == 1 and calls['first-cleanup-implicit.destroy'] == 1)
  assert(order[1] == 'claim.release' and order[2] == 'throwing.remove')
  assert(panel.dead and claim.dead and not services.panels:forSource(source))
  assert(not services.tags:find 'first-cleanup-implicit' and not services.tags:find 'second-cleanup-implicit')
  assert(not ordinary.dead and not throwing.dead and #ordinary.members == 0 and #throwing.members == 0)
  assert(services.panels:forSource(unrelatedSource) == unrelatedPanel and not unrelatedClaim.dead)
  assert(unrelatedTag:has(unrelatedPanel) and not unrelatedTag.dead and observer:active())
  assert(source.closeCalls == 0)
  assert(not callerOwner:active(), 'cleanup failure must quarantine the caller activation')
  assert(not pcall(function()
    caller:enable()
  end), 'a quarantined caller must reject enable')
  assert(loads == 1, 'cleanup failure must not reactivate the failed caller')
  if mode == 'adoption' then
    assert(subscriptions == 1 and unsubscriptions == 1)
    local duplicate = runtime:use(require '@lunette-plugins/adoption', {})
    assert(not pcall(function()
      duplicate:enable()
    end), 'failed provider cleanup must retain its exact reservation')
  end
  if started then
    started:dispose()
  end
  assert(not panel:destroy())
  windows = {}
  return {
    releaseCallbacks = fixture.releaseNativeCallbacks,
    check = function(closed)
      if mode == 'direct' or closed then
        assert(weak[1] == nil, mode .. ': failed complete cleanup must not retain the source after close')
      end
      for _, name in ipairs {
        'throwing.remove',
        'ordinary.remove',
        'first-cleanup-implicit.remove',
        'second-cleanup-implicit.remove',
        'first-cleanup-implicit.destroy',
        'second-cleanup-implicit.destroy',
        'panel.cleanupDestroy',
        'claim.release',
      } do
        assert(calls[name] == 1, name .. ' must be attempted exactly once')
      end
    end,
  }
end
