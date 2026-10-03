-- The arrangement of adopted windows in the shipped composition: a window the user drops leaves the arranged
-- set, so closing another window does not snap it back.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local TOLERANCE = 1e-5

local function expectAt(panel, x, y, z, context)
  local px, py, pz = panel.pose:getPosition()
  expect.near(px, x, TOLERANCE, context .. ', x')
  expect.near(py, y, TOLERANCE, context .. ', y')
  expect.near(pz, z, TOLERANCE, context .. ', z')
end

test('a dropped window leaves the arrangement and does not snap back when another closes', function()
  local session = testing.boot(desktop.entries())
  local native, events = session.native, session.native.events
  local panels = session:observe(panelsContract.capability)

  local first, second, third = native.newWindow(1), native.newWindow(2), native.newWindow(3)
  events.windows = { first, second, third }
  for _, window in ipairs(events.windows) do
    native.emit('onWindowOpened', { window = window })
  end
  local dragged = assert(panels.service:forSource(first))
  local _, arcY = dragged.pose:getPosition()
  expect.near(arcY, 1.5, TOLERANCE, 'an adopted window on the arc')

  -- The user drags the first window away and drops it.
  dragged:setPose(lovr.math.newMat4():translate(3, 2, -4))
  session:drop(dragged)

  -- Another window closes, and the remaining ones are arranged again.
  second.dead = true
  events.windows = { first, third }
  native.emit('onWindowClosed', { window = second })
  session:update()
  expectAt(dragged, 3, 2, -4, 'the dropped window keeps where it was dropped')
  expectAt(assert(panels.service:forSource(third)), 0, 1.5, -1.6, 'the one window left in the arrangement')
  session:close()
end)

return test
