local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local native = require '@lunette'
local runtime = plugin.runtime()
local provider = runtime:use(require '@lunette-plugins/panels', {})
provider:enable()
local owner
local service
local caller = runtime:use(
  plugin.define {
    name = 'acquisition-failure-1',
    requires = { panels = panels.capability },
    init = function(context)
      owner = context
      service = context:require(panels.capability)
    end,
  },
  {}
)
caller:enable()

local function window(id)
  return {
    id = id,
    dead = false,
    width = 800,
    height = 600,
    opaque = false,
    closeCalls = 0,
    close = function(self)
      self.closeCalls += 1
    end,
    getTexture = function()
      return false
    end,
  }
end

local existing = window(301)
local kept = service:fromWindow(owner, existing)
local source = window(302)
local claim = native.claimLayer
local fail = true
native.claimLayer = function(options)
  if fail then
    fail = false
    error 'fixture: initial claim failure'
  end
  return claim(options)
end
local before = #service:all()
local ok, failure = pcall(function()
  service:fromWindow(owner, source)
end)
assert(not ok and string.find(tostring(failure), 'fixture: initial claim failure', 1, true))
assert(#service:all() == before, 'failed initial claim must not register a panel')
assert(
  service:forSource(existing) == kept and not service:forSource(source),
  'failed claim must leave queries unchanged'
)
assert(#claims == 1, 'the failing unmanaged boundary must not acquire a native claim')
local retried = service:fromWindow(owner, source)
assert(#service:all() == before + 1 and service:forSource(source) == retried)
assert(#claims == 2 and not claims[2].dead)
caller:disable()
assert(#service:all() == 0 and not service:forSource(source), 'caller disable must leave no panels')
assert(kept.dead and retried.dead and claims[1].dead and claims[2].dead)
assert(existing.closeCalls == 0 and source.closeCalls == 0)
runtime:close()
