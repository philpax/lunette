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

return test
