local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local panels = require '@lunette-contracts/panels'
local drops = require '@lunette-contracts/drops'
local persist = require '@lunette-desktop/persist'
local vocabulary = require '@lunette-contracts/vocabulary'
local runtime = plugin.runtime()
frame.install {
  start = function() end,
  stop = function()
    runtime:close()
  end,
}
local definitions = {
  frame.definition,
  require('@lunette-plugins/panels').definition,
  require('@lunette-plugins/drops').definition,
  require('@lunette-plugins/tags').definition,
  require('@lunette-plugins/rules').definition,
  require('@lunette-plugins/placement').definition,
  require('@lunette-plugins/adoption').definition,
  require('@lunette-plugins/layouts').definition,
  require('@lunette-plugins/layout/arc').definition,
}
local providers = {}
for index, definition in ipairs(definitions) do
  providers[index] = runtime:use(definition, {})
  providers[index]:enable()
end
local service, dropService, owner
runtime
  :use(
    plugin.define {
      name = 'persistence-1',
      requires = { panels = panels.capability, drops = drops.capability },
      init = function(ctx)
        service, dropService, owner = ctx:require(panels.capability), ctx:require(drops.capability), ctx
      end,
    },
    {}
  )
  :enable()
-- The placement consumers as the composition makes them, each factory called
-- afresh, so each group starts from the arrangement file.
local FACTORIES = { persistence = true, arrange = true }
local function policy()
  local instances = {}
  for _, name in ipairs { 'workspace', 'rules', 'pose-memory', 'persistence', 'arrange', 'adoption' } do
    local module = require('@lunette-desktop/' .. name)
    local instance = runtime:use(if FACTORIES[name] then module() else module, {})
    instance:enable()
    instances[#instances + 1] = instance
  end
  return {
    dispose = function()
      for index = #instances, 1, -1 do
        instances[index]:dispose()
      end
    end,
  }
end
local first = policy()
local window = newWindow(20, 'firefox')
events.windows = { window }
emit('onWindowOpened', { window = window })
local created = service:forSource(window)
created:setPose(lovr.math.newMat4():translate(4, 3, -6))
dropService:emit(owner, { surface = created, pointer = {} })
assert(events.writes == 1)
local saved = events.saved
first:dispose()
window:setProperty(vocabulary.POSE_PROPERTY, nil)
local second = policy()
created = service:forSource(window)
local x, y, z = created.pose:getPosition()
assert(x == 4 and y == 3 and z == -6, 'saved source overrides configured rule')
second:dispose()
window:setProperty(vocabulary.POSE_PROPERTY, vocabulary.encodePose(lovr.math.newMat4():translate(8, 7, -9)))
local third = policy()
created = service:forSource(window)
x, y, z = created.pose:getPosition()
assert(x == 8 and y == 7 and z == -9, 'native source overrides saved arrangement')
third:dispose()
window:setProperty(vocabulary.POSE_PROPERTY, nil)
events.saved = 'invalid arrangement'
local refused = policy()
local reads, writes = events.reads, events.writes
for _ = 1, 3 do
  providers[4]:disable()
  assert(events.writes == writes, 'unloading cannot overwrite unreadable file')
  providers[4]:enable()
  created = service:forSource(window)
  dropService:emit(owner, { surface = created, pointer = {} })
  assert(events.writes == writes and events.saved == 'invalid arrangement')
  assert(events.reads == reads, 'refusal state survives reactivation')
end
providers[4]:disable()
assert(lovr.quit() == false)
assert(events.writes == writes, 'inactive persistence has no quit save callback')
assertResourcesReleased()
assert(saved ~= events.saved and persist.FILE == 'arrangement.state')
