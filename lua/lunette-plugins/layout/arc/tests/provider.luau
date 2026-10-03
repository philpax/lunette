-- Covers the arc provider's configuration: a configured tuning sets where the arc lays panels, and a call's
-- options merge over it.
local testing = require '@testing'
local expect = testing.expect
local layoutsContract = require '@lunette-contracts/layouts'
local arc = require '@lunette-plugins/layout/arc'

local test = testing.suite()

local function moving(width)
  local panel = { dead = false, width = width }
  function panel:setPose(pose)
    self.pose = pose
  end
  return panel
end

test("a configured radius places a panel, and a call's options merge over the configured tuning", function()
  local session = testing.start {
    'layouts',
    { id = 'layout/arc', definition = arc.definition, config = { tuning = { radius = 3 } } },
  }
  local layouts = session:observe(layoutsContract.capability).service
  expect.equal(layouts:get('arc').continuous, false, 'the arc registers as a layout that is not continuous')
  local panel = moving(1)
  layouts:apply { name = 'arc', panels = { panel } }
  local x, y, z = panel.pose:getPosition()
  expect.near(x, 0, 1e-5, 'a lone panel is centred')
  expect.near(y, 1.5, 1e-5, 'the default centre height')
  expect.near(z, -3, 1e-5, 'the configured radius')
  layouts:apply { name = 'arc', panels = { panel }, options = { radius = 2 } }
  _, y, z = panel.pose:getPosition()
  expect.near(y, 1.5, 1e-5, 'the configured centre height under a call option')
  expect.near(z, -2, 1e-5, "the call's radius")
  session:close()
end)

return test
