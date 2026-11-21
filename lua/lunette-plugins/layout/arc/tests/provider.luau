-- Covers the arc provider's configuration: the entry's tuning sets where the arc lays panels, and its name is the
-- registered layout name.
local testing = require '@testing'
local expect = testing.expect
local layoutsContract = require '@lunette-contracts/layouts'
local arc = require '../'

local test = testing.suite()

type MovingPanel = { dead: boolean, width: number, pose: Mat4?, setPose: (MovingPanel, Mat4) -> () }

local function moving(width: number): MovingPanel
  local panel: MovingPanel = { dead = false, width = width }
  function panel:setPose(pose: Mat4)
    self.pose = pose
  end
  return panel
end

test('the configured tuning places a panel under the configured name', function()
  local session = testing.start {
    'layouts',
    {
      id = 'layout/arc',
      definition = arc.definition,
      config = { name = 'wide', anchor = 'origin', tuning = { radius = 3, center = vector.pack(-1, 0.5, 0) } },
    },
  }
  local layouts = session:observe(layoutsContract.capability).service
  expect.equal(layouts:get('wide').continuous, false, 'the arc registers as a layout that is not continuous')
  local panel = moving(1)
  layouts:apply { name = 'wide', panels = { panel } }
  local x, y, z = panel.pose:getPosition()
  expect.near(x, -1, 1e-5, 'a lone panel is centred on the configured centre')
  expect.near(y, 0.5, 1e-5, 'the configured centre height')
  expect.near(z, -3, 1e-5, 'the configured radius')
  session:close()
end)

test('the head anchor places the arc ahead of a seated user looking down at the picker', function()
  local host = testing.native()
  host.events.headTracked = true
  host.events.headPose:set(lovr.math.newMat4():translate(2, 1.1, 3):rotate(math.pi / 2, 0, 1, 0):rotate(-0.8, 1, 0, 0))
  local session = testing.start {
    'layouts',
    { id = 'layout/arc', definition = arc.definition, config = { anchor = 'head' } },
  }
  local layouts = assert(session:observe(layoutsContract.capability).service)
  local first, middle, third = moving(1), moving(1), moving(1)
  layouts:apply { name = 'arc', panels = { first, middle, third } }
  local x, y, z = assert(middle.pose):getPosition()
  expect.near(x, 0.4, 1e-5, 'the radius extends in the horizontal head direction')
  expect.near(y, 1.1, 1e-5, 'the panel stays at eye height despite the head pitch')
  expect.near(z, 3, 1e-5, 'the arc is centred on the user')
  local _, _, firstZ = assert(first.pose):getPosition()
  local _, _, thirdZ = assert(third.pose):getPosition()
  expect.truthy(firstZ < z and thirdZ > z, 'the side windows keep their spacing and order')
  host.events.headTracked = false
  layouts:apply { name = 'arc', panels = { middle } }
  local fallbackX, fallbackY, fallbackZ = assert(middle.pose):getPosition()
  expect.near(fallbackX, 0, 1e-5, 'untracked head uses the configured centre')
  expect.near(fallbackY, 1.5, 1e-5, 'untracked head keeps the configured height')
  expect.near(fallbackZ, -1.6, 1e-5, 'untracked head uses the configured radius')
  session:close()
end)

return test
