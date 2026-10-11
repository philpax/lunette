-- Covers the arc provider's configuration: the entry's tuning sets where the arc lays panels, and its name is the
-- registered layout name.
local testing = require '@testing'
local expect = testing.expect
local layoutsContract = require '@lunette-contracts/layouts'
local arc = require '@lunette-plugins/layout/arc'

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
      config = { name = 'wide', tuning = { radius = 3, center = vector.pack(-1, 0.5, 0) } },
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

return test
