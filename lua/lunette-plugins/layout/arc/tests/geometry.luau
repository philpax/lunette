-- Covers the arc's spacing in `@lunette-plugins/layout/arc/geometry`.
local testing = require '@testing'
local expect = testing.expect
local geometry = require '@lunette-plugins/layout/arc/geometry'

local test = testing.suite()

local TUNING = { radius = 1.6, step = 0.55, span = math.pi * 1.2, gap = 0.05, center = vector.pack(0, 1.5, 0) }

test('an arc is centred, and does not overlap panels that fit its span or else fills the span', function()
  expect.equal(#geometry.angles({}, TUNING), 0, 'the angles of no panels')
  local one = geometry.angles({ 3 }, TUNING)
  expect.equal(#one, 1, 'the angles of one panel')
  expect.equal(one[1], 0, 'the angle of one panel, which is centred')
  local narrow = geometry.angles({ 0.1, 0.1, 0.1 }, TUNING)
  expect.near(narrow[2] - narrow[1], TUNING.step, 1e-12, 'the first step of narrow panels')
  expect.near(narrow[3] - narrow[2], TUNING.step, 1e-12, 'the second step of narrow panels')

  -- The widths are a fixed pseudo-random sequence, so the run is deterministic.
  local seed = 7
  local function nextWidth()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return 0.2 + (seed % 1000) / 1000 * 2.3
  end
  local fitted, filled = 0, 0
  for count = 2, 9 do
    local widths = {}
    for index = 1, count do
      widths[index] = nextWidth()
    end
    local angles = geometry.angles(widths, TUNING)
    expect.equal(#angles, count, 'the angles of ' .. count .. ' panels')
    expect.truthy(math.abs(angles[1] + angles[count]) < 1e-12, 'the arc of ' .. count .. ' panels is centred')
    local extent = angles[count] - angles[1]
    if extent < TUNING.span - 1e-12 then
      fitted += 1
      for index = 1, count - 1 do
        local needed = math.atan(widths[index] / 2 / TUNING.radius)
          + math.atan(widths[index + 1] / 2 / TUNING.radius)
          + TUNING.gap / TUNING.radius
        local apart = angles[index + 1] - angles[index]
        expect.truthy(apart >= needed - 1e-12, 'panels ' .. index .. ' and ' .. index + 1 .. ' do not overlap')
        expect.truthy(apart >= TUNING.step - 1e-12, 'panels ' .. index .. ' and ' .. index + 1 .. ' keep the step')
      end
    else
      filled += 1
      expect.near(extent, TUNING.span, 1e-12, 'an arc of ' .. count .. ' panels that does not fit fills the span')
    end
  end
  expect.truthy(fitted > 0 and filled > 0, 'the sequence reaches both an arc that fits and one that does not')
end)

test('poses stay on the configured circle and do not change its center', function()
  for _, center in ipairs { vector.pack(0, 0, 0), vector.pack(2, 3, -4), vector.pack(-1, 0.5, 2) } do
    local tuning = table.clone(TUNING)
    tuning.center = center
    for count = 0, 9 do
      local widths = {}
      for index = 1, count do
        widths[index] = 0.2 + index * 0.1
      end
      local poses = geometry.poses(widths, tuning)
      expect.equal(#poses, count, 'one pose per panel')
      for _, pose in ipairs(poses) do
        local position = vector.pack(pose:getPosition())
        expect.near(position.y, center.y, 1e-5, 'the center height')
        expect.near((position - center):length(), tuning.radius, 1e-5, 'the circle radius')
      end
      expect.equal(tuning.center, center, 'the center is unchanged')
    end
  end
end)

return test
