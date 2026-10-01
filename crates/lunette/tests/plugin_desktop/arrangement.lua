-- Saved placement for monitors that appear and windows that close and reopen,
-- and mirrors and adoptions that end with their panels, in the shipped desktop
-- composition.
local persist = require '@mullion/persist'

local function entry(kind, key, slot, x)
  return {
    kind = kind,
    key = key,
    slot = slot,
    pose = '1 0 0 0 0 1 0 0 0 0 1 0 ' .. x .. ' 2 -4 1',
    width = 1.25,
    height = 0.7,
    tags = {},
  }
end
events.saved = persist.render(persist.newFile {
  entry('monitor', 'fixture-output', 1, 3),
  entry('window', 'terminal', 1, 5),
  entry('window', 'terminal', 2, 7),
})
local desktop = require 'fixture/graph'()
local service = desktop.panels
local function x(panel)
  return (panel.pose:getPosition())
end

-- A monitor plugged in after startup is restored as its panel appears.
local monitor = newMonitor 'fixture-output'
events.monitors[monitor.id] = monitor
emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
local mirrored = assert(service:forSource(monitor))
assert(x(mirrored) == 3 and mirrored.width == 1.25, 'a hotplugged monitor takes its saved placement')
mirrored = nil

-- A monitor replugged before the next update is mirrored at once, and each
-- replug leaves nothing behind once its panel is gone.
local gone = setmetatable({}, { __mode = 'k' })
-- A function per replug, so no handle outlives it in a register of this chunk.
local function replug()
  local previous = service:forSource(monitor)
  gone[monitor] = true
  monitor.dead = true
  monitor = newMonitor 'fixture-output'
  events.monitors[monitor.id] = monitor
  emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
  local replugged = assert(service:forSource(monitor), 'a fast replug is mirrored before the next update')
  assert(replugged ~= previous and previous.dead, 'the panel over the old handle is retired')
  assert(x(replugged) == 3, 'a replugged monitor takes its saved placement')
end
for _ = 1, 8 do
  replug()
end
lovr.update(0.016)
collectgarbage()
collectgarbage()
assert(next(gone) == nil, 'replugged monitors are not retained by their ended mirrors')

-- The mirror is restored again when the consumer that mirrors it reloads.
desktop.consumers.base:reload { callbacks = desktop.callbacks }
assert(x(assert(service:forSource(monitor))) == 3, 'a reloaded mirror takes its saved placement')

-- Two windows of one application take the two saved slots. One closes, and a
-- window that opens next takes the slot it left.
local first, second = newWindow(1), newWindow(2)
events.windows = { first, second }
emit('onWindowOpened', { window = first })
emit('onWindowOpened', { window = second })
assert(x(service:forSource(first)) == 5 and x(service:forSource(second)) == 7)
local closed = setmetatable({ [first] = true }, { __mode = 'k' })
first.dead = true
events.windows = { second }
emit('onWindowClosed', { window = first })
lovr.update(0.016)
first = nil
local reopened = newWindow(3)
events.windows = { second, reopened }
emit('onWindowOpened', { window = reopened })
assert(x(service:forSource(reopened)) == 5, 'a reopened window takes the slot of the one that closed')
assert(x(service:forSource(second)) == 7, 'the other window keeps its slot')
collectgarbage()
collectgarbage()
assert(next(closed) == nil, 'a closed window is not retained by its ended adoption or slot')

-- Rules, layout, and policy require tags, and adoption requires rules, so a
-- tags outage withdraws the adopted panels and leaves rendering. Recovery
-- adopts the windows again into the slots they hold.
local adopted = service:forSource(reopened)
desktop.providers.tags:disable()
for _, name in ipairs { 'rules', 'adoption', 'layout/arc' } do
  assert(desktop.providers[name]:state() ~= 'active', 'a tags outage unloads ' .. name)
end
assert(desktop.consumers.policy:state() ~= 'active', 'a tags outage unloads the policy')
assert(desktop.consumers.base:state() == 'active', 'a tags outage keeps rendering')
assert(adopted.dead and service:forSource(reopened) == nil, 'a tags outage withdraws adopted panels')
desktop.providers.tags:enable()
assert(desktop.consumers.policy:state() == 'active', 'recovery restores the policy')
assert(x(service:forSource(reopened)) == 5 and x(service:forSource(second)) == 7, 'recovery restores the slots')
assert(lovr.quit() == false)
