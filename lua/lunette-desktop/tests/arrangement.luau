-- Covers the saved arrangement in the shipped desktop as monitors appear and windows close and reopen: a
-- hotplugged or replugged monitor takes its saved placement, windows of one application take its saved slots
-- in order, nothing ended is retained, and a tags outage withdraws and restores the adoptions.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local persist = require '@lunette-plugins/arrangement/format'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

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

local function start()
  local fake = testing.native()
  fake.events.saved = persist.render(persist.newFile {
    entry('monitor', 'fixture-output', 1, 3),
    entry('window', 'terminal', 1, 5),
    entry('window', 'terminal', 2, 7),
  })
  local session = testing.boot(desktop.entries(), { native = fake })
  return session, session:observe(panelsContract.capability)
end

local function x(panel)
  return (panel.pose:getPosition())
end

test('a hotplugged, replugged, or remirrored monitor takes its saved placement and is not retained', function()
  local session, panels = start()
  local native, events = session.native, session.native.events
  local function plug()
    local monitor = native.newMonitor 'fixture-output'
    events.monitors[monitor.id] = monitor
    native.emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
    return monitor
  end
  local monitor = plug()
  local mirrored = assert(panels.service:forSource(monitor))
  expect.near(x(mirrored), 3, 1e-5, 'a hotplugged monitor takes its saved placement')
  expect.equal(mirrored.width, 1.25, 'and its saved size')
  mirrored = nil

  -- Replugging creates a new mirror before the next update and releases the prior monitor handle.
  local gone = setmetatable({}, { __mode = 'k' })
  local function replug()
    local previous = panels.service:forSource(monitor)
    gone[monitor] = true
    monitor.dead = true
    monitor = plug()
    local replugged = assert(panels.service:forSource(monitor), 'a fast replug is mirrored before the next update')
    expect.truthy(replugged ~= previous and previous.dead, 'the panel over the old handle is retired')
    expect.near(x(replugged), 3, 1e-5, 'a replugged monitor takes its saved placement')
  end
  for _ = 1, 8 do
    replug()
  end
  session:update()
  testing.collect()
  expect.equal(next(gone), nil, 'replugged monitors are not retained by their ended mirrors')

  session.instances['desktop/monitors']:reload {}
  expect.near(x(assert(panels.service:forSource(monitor))), 3, 1e-5, 'a reloaded mirror takes its saved placement')
  session:close()
end)

test('windows of one application take its saved slots, and a reopened window takes the slot left free', function()
  local session, panels = start()
  local native, events = session.native, session.native.events
  local first, second = native.newWindow(1), native.newWindow(2)
  events.windows = { first, second }
  native.emit('onWindowOpened', { window = first })
  native.emit('onWindowOpened', { window = second })
  expect.near(x(panels.service:forSource(first)), 5, 1e-5, 'the first slot')
  expect.near(x(panels.service:forSource(second)), 7, 1e-5, 'the second slot')
  local closed = setmetatable({ [first] = true }, { __mode = 'k' })
  first.dead = true
  events.windows = { second }
  native.emit('onWindowClosed', { window = first })
  session:update()
  first = nil
  local reopened = native.newWindow(3)
  events.windows = { second, reopened }
  native.emit('onWindowOpened', { window = reopened })
  expect.near(x(panels.service:forSource(reopened)), 5, 1e-5, 'a reopened window takes the slot left free')
  expect.near(x(panels.service:forSource(second)), 7, 1e-5, 'the other window keeps its slot')
  testing.collect()
  expect.equal(next(closed), nil, 'a closed window is not retained by its ended adoption or slot')

  -- A tags outage withdraws adoption-dependent panels but keeps rules, rendering, mirrors, and layouts active.
  local adopted = panels.service:forSource(reopened)
  local instances = session.instances
  instances.tags:disable()
  for _, id in ipairs { 'placement', 'adoption', 'desktop/workspaces', 'desktop/persistence', 'desktop/arrange' } do
    expect.truthy(instances[id]:state() ~= 'active', 'a tags outage unloads ' .. id)
  end
  for _, id in ipairs { 'rules', 'desktop/rules', 'layout/arc', 'desktop/render', 'desktop/monitors' } do
    expect.equal(instances[id]:state(), 'active', 'a tags outage keeps ' .. id)
  end
  expect.truthy(adopted.dead and panels.service:forSource(reopened) == nil, 'the adopted panels are withdrawn')
  instances.tags:enable()
  expect.equal(instances['desktop/adoption']:state(), 'active', 'recovery restores adoption')
  expect.near(x(panels.service:forSource(reopened)), 5, 1e-5, 'recovery restores the first slot')
  expect.near(x(panels.service:forSource(second)), 7, 1e-5, 'recovery restores the second slot')
  session:close()
end)

return test
