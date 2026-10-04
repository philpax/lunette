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

test('a call replaces the configured vector center atomically and leaves it unchanged', function()
  local center = vector.pack(2, 3, 4)
  local session = testing.start {
    'layouts',
    { id = 'layout/arc', definition = arc.definition, config = { tuning = { radius = 3, center = center } } },
  }
  local layouts = session:observe(layoutsContract.capability).service
  local panel = moving(1)
  layouts:apply { name = 'arc', panels = { panel } }
  local x, y, z = panel.pose:getPosition()
  expect.near(x, 2, 1e-5, 'the configured center x')
  expect.near(y, 3, 1e-5, 'the configured center y')
  expect.near(z, 1, 1e-5, 'the configured center z minus the radius')
  local replacement = vector.pack(-1, 0.5, -2)
  layouts:apply { name = 'arc', panels = { panel }, options = { center = replacement } }
  x, y, z = panel.pose:getPosition()
  expect.near(x, -1, 1e-5, 'the replacement center x')
  expect.near(y, 0.5, 1e-5, 'the replacement center y')
  expect.near(z, -5, 1e-5, 'the replacement center z keeps the radius')
  expect.equal(center, vector.pack(2, 3, 4), 'the configured center is unchanged')
  expect.equal(replacement, vector.pack(-1, 0.5, -2), 'the replacement is unchanged')
  session:close()
end)

return test
