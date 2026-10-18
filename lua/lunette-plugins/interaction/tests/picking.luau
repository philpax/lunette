local testing = require '@testing'
local expect = testing.expect
local picking = require '../picking'
local test = testing.suite()

-- A surface the ray hits at a fixed distance, with an optional pick priority.
local function surface(distance: number, priority: number?): any
  return {
    dead = false,
    pickPriority = priority,
    raycast = function(_self: any, _origin: vector, _direction: vector): (number, number, number)
      return 1, 2, distance
    end,
  }
end

local ORIGIN = vector.pack(0, 0, 0)
local AHEAD = vector.pack(0, 0, -1)

test('without priorities the nearest hit wins', function()
  local near, far = surface(1), surface(2)
  expect.equal(picking.pick({ far, near }, ORIGIN, AHEAD, 10), near, 'the nearer surface')
end)

test('a higher pick priority wins over a nearer hit', function()
  local near, behind = surface(1), surface(2, 10)
  expect.equal(picking.pick({ near, behind }, ORIGIN, AHEAD, 10), behind, 'the prioritised surface')
  expect.equal(picking.pick({ behind, near }, ORIGIN, AHEAD, 10), behind, 'independent of order')
end)

test('equal priorities fall back to distance, and reach still applies', function()
  local near, far = surface(1, 5), surface(2, 5)
  expect.equal(picking.pick({ far, near }, ORIGIN, AHEAD, 10), near, 'the nearer of equal priority')
  local beyond = surface(20, 10)
  expect.equal(picking.pick({ near, beyond }, ORIGIN, AHEAD, 10), near, 'a surface beyond reach is not hit')
end)

test('a negative priority loses to an unprioritised surface', function()
  local low, plain = surface(1, -1), surface(2)
  expect.equal(picking.pick({ low, plain }, ORIGIN, AHEAD, 10), plain, 'nil counts as zero')
  expect.equal(picking.pick({ low }, ORIGIN, AHEAD, 10), low, 'a lone surface is still hit')
end)

return test
