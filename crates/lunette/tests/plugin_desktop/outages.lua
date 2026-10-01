local plugin = require '@lunette-plugin'
local callbacks = require 'desktop/callbacks'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local keyboard = require '@lunette-contracts/keyboard'
local display = require '@lunette-contracts/error-display'
local runtime = plugin.runtime()
callbacks.install(function() end, function()
  runtime:close()
end)
local definitions = {
  panels = require '@lunette-plugins/panels',
  interaction = require '@lunette-plugins/interaction',
  laser = require '@lunette-plugins/laser',
  keyboard = require '@lunette-plugins/keyboard',
  tags = require '@lunette-plugins/tags',
  rules = require '@lunette-plugins/rules',
  adoption = require '@lunette-plugins/adoption',
  arc = require '@lunette-plugins/layout/arc',
  display = require('@lunette-plugins/error-display').definition,
}
local providers = {}
for _, name in ipairs { 'panels', 'interaction', 'laser', 'keyboard', 'tags', 'rules', 'adoption', 'arc', 'display' } do
  providers[name] = runtime:use(definitions[name], {})
  providers[name]:enable()
end
local function use(name)
  local instance = runtime:use(require('desktop/' .. name), { callbacks = callbacks })
  instance:enable()
  return instance
end
local base = use 'base'
use 'pointing'
use 'input'
use 'keyboard'
use 'errors'
local definePolicy = require 'desktop/policy'
local policy = runtime:use(definePolicy(), { callbacks = callbacks })
policy:enable()
local service, focus, placement, tagService, owner
runtime
  :use(
    plugin.define(function(config)
      return config
    end, {
      panels = panels.capability,
      interaction = interaction.capability,
      rules = rules.capability,
      tags = tags.capability,
    }, {}, function(ctx)
      service, focus, placement, tagService, owner =
        ctx:require(panels.capability),
        ctx:require(interaction.capability),
        ctx:require(rules.capability),
        ctx:require(tags.capability),
        ctx
    end),
    {}
  )
  :enable()
local function sources()
  local list = placement:sources()
  assert(#list == 3)
  assert(list[1].precedence == 100 and list[2].precedence == 200 and list[3].precedence == 300)
  assert(list[2].name == 'mullion.persist' and list[3].name == 'lunette.adoption')
end
sources()
events.windows = { newWindow(10), newWindow(11, 'firefox') }
for _, window in ipairs(events.windows) do
  emit('onWindowOpened', { window = window })
end
local initial = service:forSource(events.windows[1])
local firefox = service:forSource(events.windows[2])
assert(firefox.width == 2)
local x = firefox.pose:getPosition()
assert(x == -1.4, 'configured rule pose remains outside the arc')
initial:setPose(lovr.math.newMat4():translate(3, 2, -4))
service:emitDropped(owner, initial, {})
assert(events.writes == 1)
local stable = service
for _ = 1, 3 do
  providers.keyboard:disable()
  assert(service == stable and service:forSource(events.windows[1]) == initial)
  assert(subscriptionCount 'onError' == 1 and subscriptionCount 'onWindowOpened' == 1)
  local surfaces = callbacks.surfaces()
  assert(#surfaces == 2, 'keyboard outage removes only wrist/keyboard surfaces')
  lovr.update(0.016)
  assert(lovr.draw(events.pass) == false)
  sources()
  providers.keyboard:enable()
  assert(#callbacks.surfaces() == 3)
  local wrist = callbacks.surfaces()[3]
  wrist:onPress(nil, nil, {})
  assert(#callbacks.surfaces() == 4, 'recovery lazily creates one keyboard')
  providers.display:disable()
  assert(subscriptionCount 'onError' == 0)
  assert(service:forSource(events.windows[1]) == initial)
  sources()
  lovr.update(0.016)
  assert(lovr.draw(events.pass) == false)
  providers.display:enable()
  assert(subscriptionCount 'onError' == 1)
end
local reads, writes = events.reads, events.writes
for _ = 1, 3 do
  providers.rules:disable()
  assert(initial.dead, 'policy outage withdraws adopted panels')
  assert(subscriptionCount 'onWindowOpened' == 0)
  assert(events.writes == writes, 'policy teardown never saves')
  for _, record in ipairs(events.subscriptions.onWindowOpened) do
    if not record.active then
      record.callback { window = events.windows[1] }
    end
  end
  assert(service:forSource(events.windows[1]) == nil, 'retained native callback cannot place after deactivation')
  lovr.update(0.016)
  lovr.draw(events.pass)
  providers.rules:enable()
  sources()
  initial = service:forSource(events.windows[1])
  local px, py, pz = initial.pose:getPosition()
  assert(px == 3 and py == 2 and pz == -4, 'retained arrangement restores after policy outage')
  assert(events.reads == reads, 'outage does not reconstruct persistent state')
  assert(subscriptionCount 'onWindowOpened' == 1)
end
local monitor = newMonitor 'fixture-output'
events.monitors[monitor.id] = monitor
emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
assert(service:forSource(monitor))
base:disable()
assert(service:forSource(monitor) == nil, 'base owns its mirrors')
assert(not events.windows[1].dead and events.closed == 0)
assert(events.unmirrored == 1, 'base cleanup stops its capture')
base:enable()
assert(service:forSource(monitor), 'base recovery remirrors connected outputs')
assert(events.mirrored == 2)
base:reload { callbacks = callbacks }
assert(events.mirrored == 3 and events.unmirrored == 2, 'replacement releases previous capture')
monitor.dead = true
lovr.update(0.016)
monitor = newMonitor 'fixture-output'
events.monitors[monitor.id] = monitor
emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
assert(service:forSource(monitor), 'reconnected output gets a new owned panel')
providers.display:disable()
events.reported = {}
events.writeMode = 'refuse'
assert(lovr.quit() == false)
assert(
  #events.reported == 1 and events.reported[1].message:find('arrangement was not saved', 1, true),
  'the native report survives a display outage'
)
assertResourcesReleased()
