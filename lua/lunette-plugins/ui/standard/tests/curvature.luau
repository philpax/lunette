-- Covers lua/lunette-plugins/ui/standard/private/curvature.luau: the Settings control's degree vocabulary.

local testing = require '@testing'
local expect = testing.expect
local curvature = require '../private/curvature'

local test = testing.suite()

local function bend(
  curve: number,
  axis: number,
  width: number,
  height: number
): { curve: number, axis: number, width: number, height: number }
  return { curve = curve, axis = axis, width = width, height = height }
end

test('bend degrees round-trip through the curve for every axis', function()
  for _, axis in { 0, math.pi / 4, math.pi / 2, -math.pi / 3 } do
    for _, degrees in { 0, 45, -45, 120, -120 } do
      local curve = curvature.curve(degrees, axis, 0.6, 0.4)
      local read = curvature.read(bend(curve, axis, 0.6, 0.4))
      expect.near(read.bend, degrees, 1e-9, `{degrees} about {axis}`)
      expect.near(read.axis, curvature.wrapAxis(math.deg(axis)), 1e-9, `the axis of {degrees}`)
    end
  end
end)

test('an axis wraps into the control range', function()
  expect.near(curvature.wrapAxis(0), 0, 1e-12, 'zero')
  expect.near(curvature.wrapAxis(180), 180, 1e-12, 'the end')
  expect.near(curvature.wrapAxis(181), -179, 1e-12, 'just past the end')
  expect.near(curvature.wrapAxis(-180), 180, 1e-12, 'the start maps to the end')
  expect.near(curvature.wrapAxis(-181), 179, 1e-12, 'just before the start')
  expect.near(curvature.wrapAxis(540), 180, 1e-12, 'a full turn and a half')
end)

test('a zero-size panel has no bend', function()
  expect.equal(curvature.curve(90, 0, 0, 0), 0, 'no curve')
  local read = curvature.read(bend(0, 0, 0, 0))
  expect.equal(read.bend, 0, 'no bend')
  expect.equal(read.axis, 0, 'no axis')
end)

test('the control limits are the half-turn', function()
  expect.equal(curvature.MAX_BEND, 180, 'the bend')
  expect.equal(curvature.MAX_AXIS, 180, 'the axis')
  local half = curvature.curve(curvature.MAX_BEND, 0, 0.6, 0.4)
  expect.near(curvature.read(bend(half, 0, 0.6, 0.4)).bend, 180, 1e-9, 'a half-turn reads as the limit')
end)

test('numeric text parses only inside its range', function()
  expect.equal(curvature.parse('45', -180, 180), 45, 'a value inside')
  expect.equal(curvature.parse('-45', 0, 180), nil, 'below the range')
  expect.equal(curvature.parse('181', -180, 180), nil, 'above the range')
  expect.equal(curvature.parse('12x', -180, 180), nil, 'not a number')
  expect.equal(curvature.parse('nan', -180, 180), nil, 'not a number')
end)

test('a numeric value formats to one decimal', function()
  expect.equal(curvature.format(0), '0.0', 'zero')
  expect.equal(curvature.format(45), '45.0', 'a whole number')
  expect.equal(curvature.format(-12.34), '-12.3', 'rounded')
end)

return test
