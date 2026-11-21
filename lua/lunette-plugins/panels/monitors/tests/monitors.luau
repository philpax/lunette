local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local menuContract = require '@lunette-contracts/menu'

type Config = testing.ConfiguredInput<typeof(require('../').define)>

local test = testing.suite()

local TOLERANCE = 1e-5

-- A monitor that the host reports to the consumer.
local function plug(native: testing.Native, name: string): testing.Monitor
  local monitor = native.newMonitor(name)
  native.events.monitors[monitor.id] = monitor
  return monitor
end

-- A monitor plugged in while the consumer runs.
local function hotplug(native: testing.Native, name: string): testing.Monitor
  local monitor = plug(native, name)
  native.emit('onMonitorAdded', { monitor = monitor })
  return monitor
end

-- The consumer with `config` over the panels and tags providers, started once `native` reports its monitors.
local function start(native: testing.Native, config: Config): (testing.Session, panelsContract.Service)
  local session = testing.start {
    'theme',
    'panels',
    'tags',
    { id = 'desktop/monitors', definition = require('../').definition, config = config },
  }
  return session, session:observe(panelsContract.capability).service
end

local function xOf(panels: panelsContract.Service, monitor: testing.Monitor): number
  local x = assert(panels:forSource(monitor), 'the mirror of ' .. monitor.name).pose:getPosition()
  return x
end

test('mirrors are placed side by side in name order, and one that goes away leaves its place', function()
  local native = testing.native()
  local b, a = plug(native, 'B'), plug(native, 'A')
  local session, panels = start(native, {})
  expect.near(xOf(panels, a), 0, TOLERANCE, 'the first mirror by name')
  expect.near(xOf(panels, b), 2.1, TOLERANCE, 'the second mirror, to the right')
  expect.equal(assert(panels:forSource(a)).width, 2, 'the default width')
  expect.near(xOf(panels, hotplug(native, 'C')), -2.1, TOLERANCE, 'a third mirror, to the left')
  local second = assert(panels:forSource(b))
  b.dead = true
  native.events.monitors[b.id] = nil
  panels:update()
  expect.truthy(second.dead, 'the mirror of a monitor that went away')
  expect.near(xOf(panels, hotplug(native, 'D')), 2.1, TOLERANCE, 'a new mirror in the freed place')
  session:close()
end)

test('select names the mirrored monitors and placement sets the row', function()
  local native = testing.native()
  local e, f = plug(native, 'E'), plug(native, 'F')
  local session, panels = start(native, {
    select = { 'F', 'G' },
    placement = { center = vector.pack(1, 2, -3), width = 1, gap = 0.5 },
  })
  expect.equal(panels:forSource(e), nil, 'an unselected monitor')
  local mirrored = assert(panels:forSource(f))
  local x, y, z = mirrored.pose:getPosition()
  expect.near(x, 1, TOLERANCE, 'the first mirror, x')
  expect.near(y, 2, TOLERANCE, 'the first mirror, y')
  expect.near(z, -3, TOLERANCE, 'the first mirror, z')
  expect.equal(mirrored.width, 1, 'the configured width')
  expect.near(xOf(panels, hotplug(native, 'G')), 2.5, TOLERANCE, 'the next, a width and a gap to the right')
  session:close()
end)

test('mirrors join a configured tag made after them', function()
  local native = testing.native()
  local first = plug(native, 'A')
  local session, panels = start(native, { tags = { 'main' } })
  local tags = session:observe(tagsContract.capability)
  local mirrored = assert(panels:forSource(first))
  local main = tags.service:hold(tags.context, { name = 'main' })
  expect.truthy(main:has(mirrored), 'a mirror in a tag made after it')
  expect.truthy(main:has(assert(panels:forSource(hotplug(native, 'B')))), 'a mirror made after the tag')
  session:close()
end)

test('a display requiring explicit sharing starts closed and can be shared and stopped from the wrist menu', function()
  local native = testing.native()
  local monitor = plug(native, 'A')
  monitor.explicitShare = true
  local session = testing.start {
    'theme',
    'panels',
    'menu',
    'frame',
    { id = 'desktop/monitors', definition = require('../').definition },
  }
  local panels = session:observe(panelsContract.capability).service
  local menu = session:observe(menuContract.capability).service
  expect.equal(panels:forSource(monitor), nil, 'start without a display share')
  expect.falsy(monitor.mirrored, 'enumeration does not start capture')
  expect.equal(menu:invoke('desktop/monitors/A').kind, 'invoked')
  expect.truthy(panels:forSource(monitor), 'open the display panel')
  expect.truthy(monitor.mirrored, 'start capture after selection')
  expect.equal(menu:invoke('desktop/monitors/A').kind, 'invoked')
  expect.equal(panels:forSource(monitor), nil, 'remove the display panel')
  expect.falsy(monitor.mirrored, 'stop capture')
  local second = plug(native, 'B')
  second.explicitShare = true
  native.emit('onMonitorAdded', { monitor = second })
  expect.falsy(second.mirrored, 'hotplug does not start capture')
  expect.equal(menu:invoke('desktop/monitors/B').kind, 'invoked', 'the new display is selectable')
  session:close()
end)

return test
