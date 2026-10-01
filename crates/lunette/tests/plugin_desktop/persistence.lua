local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local persist = require '@mullion/persist'
local pose = require '@mullion/pose'
local runtime = plugin.runtime()
frame.install {
  start = function() end,
  stop = function()
    runtime:close()
  end,
}
local definitions = {
  frame.definition,
  require '@lunette-plugins/panels',
  require '@lunette-plugins/interaction',
  require '@lunette-plugins/tags',
  require '@lunette-plugins/rules',
  require '@lunette-plugins/adoption',
  require '@lunette-plugins/layout/arc',
}
local providers = {}
for index, definition in ipairs(definitions) do
  providers[index] = runtime:use(definition, {})
  providers[index]:enable()
end
local service, owner
runtime
  :use(
    plugin.define {
      name = 'persistence-1',
      requires = { panels = panels.capability },
      init = function(ctx)
        service, owner = ctx:require(panels.capability), ctx
      end,
    },
    {}
  )
  :enable()
local definePolicy = require 'desktop/policy'
local function policy()
  local instance = runtime:use(definePolicy(), {})
  instance:enable()
  return instance
end
local first = policy()
local window = newWindow(20, 'firefox')
events.windows = { window }
emit('onWindowOpened', { window = window })
local created = service:forSource(window)
created:setPose(lovr.math.newMat4():translate(4, 3, -6))
service:emitDropped(owner, created, {})
assert(events.writes == 1)
local saved = events.saved
first:dispose()
window:setProperty('mullion.pose', nil)
local second = policy()
created = service:forSource(window)
local x, y, z = created.pose:getPosition()
assert(x == 4 and y == 3 and z == -6, 'saved source overrides configured rule')
second:dispose()
window:setProperty('mullion.pose', pose.encode(lovr.math.newMat4():translate(8, 7, -9)))
local third = policy()
created = service:forSource(window)
x, y, z = created.pose:getPosition()
assert(x == 8 and y == 7 and z == -9, 'native source overrides saved arrangement')
third:dispose()
window:setProperty('mullion.pose', nil)
events.saved = 'invalid arrangement'
local refused = policy()
local reads, writes = events.reads, events.writes
for _ = 1, 3 do
  providers[4]:disable()
  assert(events.writes == writes, 'unloading cannot overwrite unreadable file')
  providers[4]:enable()
  created = service:forSource(window)
  service:emitDropped(owner, created, {})
  assert(events.writes == writes and events.saved == 'invalid arrangement')
  assert(events.reads == reads, 'refusal state survives reactivation')
end
providers[4]:disable()
assert(lovr.quit() == false)
assert(events.writes == writes, 'inactive policy has no quit save callback')
assertResourcesReleased()
assert(saved ~= events.saved and persist.FILE == 'arrangement.state')
