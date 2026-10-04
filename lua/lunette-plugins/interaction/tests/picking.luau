local testing = require '@testing'
local expect = testing.expect

local picking = require '@lunette-plugins/interaction/picking'

local test = testing.suite()

test('a deflection inside the dead zone is nothing, and the response starts at its edge', function()
  for _, dead in ipairs { 0, 0.1, 0.2, 0.5 } do
    for step = -20, 20 do
      local value = step / 20
      local response = picking.deadZone(value, dead)
      local where = 'dead zone ' .. dead .. ', deflection ' .. value
      if math.abs(value) <= dead then
        expect.equal(response, 0, where)
      else
        expect.truthy(math.abs(response) <= 1 + 1e-12, where .. ': at most a full deflection')
        expect.equal(response < 0, value < 0, where .. ': the sign is kept')
      end
      expect.near(picking.deadZone(-value, dead), -response, 1e-12, where .. ': odd')
    end
    expect.near(picking.deadZone(1, dead), 1, 1e-12, 'a full deflection is full')
    expect.near(picking.deadZone(dead + 1e-9, dead), 0, 1e-6, 'continuous at the edge')
  end
  expect.equal(picking.deadZone(0 / 0, 0.2), 0, 'a nan')
  expect.equal(picking.deadZone(1, 1), 0, 'a dead zone of the whole range')
end)

local function surface(distance, record)
  return {
    dead = false,
    raycast = function(_self, _origin, direction)
      if record then
        record.length = direction:length()
      end
      return 1, 2, distance
    end,
  }
end

test('the nearest live surface within reach is picked', function()
  local near, far, dead = surface(2), surface(1.5), surface(0.5)
  dead.dead = true
  local beyond = surface(0.1)
  local hit, x, y, distance = picking.pick({ near, far, dead }, vector.pack(0, 0, 0), vector.pack(0, 0, -1), 8)
  expect.equal(hit, far, 'the nearer live surface')
  expect.equal(x, 1, 'x')
  expect.equal(y, 2, 'y')
  expect.equal(distance, 1.5, 'distance')
  beyond.raycast = function()
    return 1, 2, 9
  end
  expect.falsy(picking.pick({ beyond }, vector.pack(0, 0, 0), vector.pack(0, 0, -1), 8), 'out of reach')
  expect.falsy(picking.pick({ near }, vector.pack(0, 0, 0), vector.pack(0, 0, 0), 8), 'no direction')
end)

test('a surface is asked with a unit direction', function()
  local record = {}
  picking.pick({ surface(1, record) }, vector.pack(0, 0, 0), vector.pack(0, 3, -4), 8)
  expect.near(record.length, 1, 1e-6, 'the direction length')
end)

test('a scroll is scaled by the frame time and flips vertically', function()
  local tuning = {
    reach = 8,
    grabDeadZone = 0,
    scrollScale = 100,
    scrollDeadZone = 0,
    reachScale = 1,
    reachMinimum = 0,
    reachMaximum = 1,
    resizeMinimum = 0,
    resizeMaximum = 1,
  }
  local dx, dy = picking.scrollDelta { x = 0.5, y = 0.5, dt = 0.1, tuning = tuning }
  expect.near(dx, 5, 1e-9, 'horizontal')
  expect.near(dy, -5, 1e-9, 'vertical')
  dx, dy = picking.scrollDelta { x = 1, y = 1, tuning = tuning }
  expect.equal(dx, 0, 'no frame time, no horizontal scroll')
  expect.equal(dy == 0, true, 'no frame time, no vertical scroll')
end)

return test
