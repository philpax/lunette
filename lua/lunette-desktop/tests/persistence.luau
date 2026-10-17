-- A dropped window leaves the arrangement, is saved, and is restored where it was dropped in the next session.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local function expectAt(panel: panelsContract.Panel, x: number, y: number, z: number, context: string)
  local px, py, pz = panel.pose:getPosition()
  expect.near(px, x, 1e-5, context .. ', x')
  expect.near(py, y, 1e-5, context .. ', y')
  expect.near(pz, z, 1e-5, context .. ', z')
end

test('a dropped window keeps its pose as others close, and the next session restores it', function()
  local session = testing.boot(desktop.compose())
  local native, events = session.native, session.native.events
  local panels = session:observe(panelsContract.capability).service
  local first, second, third = native.newWindow(1), native.newWindow(2), native.newWindow(3)
  events.windows = { first, second, third }
  for _, window in events.windows do
    native.emit('onWindowOpened', { window = window })
  end
  local dropped = assert(panels:forSource(first))
  dropped:setPose(lovr.math.newMat4():translate(3, 2, -4))
  session:drop(dropped)
  expect.equal(events.writes, 1, 'the drop saves the arrangement')

  second.dead = true
  events.windows = { first, third }
  native.emit('onWindowClosed', { window = second })
  session:update()
  expectAt(dropped, 3, 2, -4, 'the dropped window does not snap back')
  expectAt(assert(panels:forSource(third)), 0, 1.5, -1.6, 'the one window left in the arrangement')
  expect.equal(session:quit(), false, 'quit does not veto')
  local saved = events.saved
  session:close()

  local fake = testing.native()
  fake.events.saved = saved
  session = testing.boot(desktop.compose(), { native = fake })
  panels = session:observe(panelsContract.capability).service
  local reopened = fake.newWindow(4)
  fake.events.windows = { reopened }
  fake.emit('onWindowOpened', { window = reopened })
  expectAt(assert(panels:forSource(reopened)), 3, 2, -4, 'the next session restores the saved pose')
  session:close()
end)

-- Boots the desktop with the saved arrangement and the given monitors present.
local function boot(saved: string?, monitors: { string }): (testing.Session, testing.Native)
  local fake = testing.native()
  fake.events.saved = saved
  for _, id in monitors do
    table.insert(fake.events.monitors, fake.newMonitor(id))
  end
  return testing.boot(desktop.compose(), { native = fake }), fake
end

local function mirrorOf(session: testing.Session, native: testing.Native, id: string): panelsContract.Panel
  local panels = session:observe(panelsContract.capability).service
  for _, monitor in native.events.monitors do
    if monitor.id == id then
      return assert(panels:forSource(monitor), `no mirror of {id}`)
    end
  end
  error(`no monitor {id}`)
end

test('a moved monitor mirror returns where it was left, present at startup or arriving later', function()
  local session, native = boot(nil, { 'monitor-a' })
  local mirror = mirrorOf(session, native, 'monitor-a')
  mirror:setPose(lovr.math.newMat4():translate(-2, 1.8, -3))
  session:drop(mirror)
  local saved = native.events.saved
  session:close()

  session, native = boot(saved, { 'monitor-a' })
  expectAt(mirrorOf(session, native, 'monitor-a'), -2, 1.8, -3, 'a monitor present at startup')
  session:close()

  session, native = boot(saved, {})
  local late = native.newMonitor 'monitor-a'
  table.insert(native.events.monitors, late)
  native.emit('onMonitorAdded', { monitor = late })
  session:update()
  expectAt(mirrorOf(session, native, 'monitor-a'), -2, 1.8, -3, 'a monitor that arrives after startup')
  session:close()
end)

test('a save while a mirrored monitor or an application is absent keeps its saved place', function()
  local session, native = boot(nil, { 'monitor-a' })
  local window = native.newWindow(1)
  native.events.windows = { window }
  native.emit('onWindowOpened', { window = window })
  local panels = session:observe(panelsContract.capability).service
  local mirror = mirrorOf(session, native, 'monitor-a')
  mirror:setPose(lovr.math.newMat4():translate(-2, 1.8, -3))
  local windowPanel = assert(panels:forSource(window))
  windowPanel:setPose(lovr.math.newMat4():translate(2, 1.4, -2))
  session:drop(mirror)
  local saved = native.events.saved
  session:close()

  -- Neither the monitor nor the application is present, and a drop of another window saves.
  session, native = boot(saved, {})
  panels = session:observe(panelsContract.capability).service
  local other = native.newWindow(2, 'org.fixture.Other')
  native.events.windows = { other }
  native.emit('onWindowOpened', { window = other })
  session:drop(assert(panels:forSource(other)))
  saved = native.events.saved
  session:close()

  session, native = boot(saved, { 'monitor-a' })
  expectAt(mirrorOf(session, native, 'monitor-a'), -2, 1.8, -3, 'the absent monitor keeps its place')
  panels = session:observe(panelsContract.capability).service
  local back = native.newWindow(3)
  native.events.windows = { back }
  native.emit('onWindowOpened', { window = back })
  expectAt(assert(panels:forSource(back)), 2, 1.4, -2, 'the closed application keeps its place')
  session:close()
end)

return test
