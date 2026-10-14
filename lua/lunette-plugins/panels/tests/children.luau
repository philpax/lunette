local testing = require '@testing'
local expect = testing.expect

local children = require '@lunette-plugins/panels/children'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'

local test = testing.suite()

-- A 2 by 1 metre panel over a 1000 by 500 window: 500 surface units to the metre.
type Crop = { read x: number, read y: number, read width: number, read height: number }
type Child = { read x: number, read y: number, read width: number, read height: number, read crop: Crop }
type Vertices = { { number } }

local PANEL = { width = 2, height = 1, curve = 0 }
local WINDOW_WIDTH, WINDOW_HEIGHT = 1000, 500
local SQUARE = geometry.perimeter({ x = 0, y = 0, width = 2, height = 1 }, geometry.uniform(0))
local FULL = { x = 0, y = 0, width = 1, height = 1 }

local function child(x: number, y: number, width: number, height: number, crop: Crop?): Child
  return { x = x, y = y, width = width, height = height, crop = crop or FULL }
end

-- The panel-local bounds of the vertices, from the top-left, in metres.
local function extent(vertices: Vertices): (number, number, number, number)
  local left, right, top, bottom = math.huge, -math.huge, math.huge, -math.huge
  for _, vertex in vertices do
    local x, y = vertex[1] + PANEL.width / 2, PANEL.height / 2 - vertex[2]
    left, right = math.min(left, x), math.max(right, x)
    top, bottom = math.min(top, y), math.max(bottom, y)
  end
  return left, top, right, bottom
end

local function uvExtent(vertices: Vertices): (number, number, number, number)
  local left, right, top, bottom = math.huge, -math.huge, math.huge, -math.huge
  for _, vertex in vertices do
    left, right = math.min(left, vertex[7]), math.max(right, vertex[7])
    top, bottom = math.min(top, vertex[8]), math.max(bottom, vertex[8])
  end
  return left, top, right, bottom
end

test('a child inside the window covers its own rectangle and samples its whole crop', function()
  local crop = { x = 0.25, y = 0, width = 0.5, height = 0.5 }
  local vertices, indices =
    children.geometry(PANEL, SQUARE, WINDOW_WIDTH, WINDOW_HEIGHT, child(100, 50, 200, 100, crop))
  assert(vertices and indices, 'the child is drawn')
  expect.equal(#indices % 3, 0, 'whole triangles')
  local left, top, right, bottom = extent(vertices)
  expect.near(left, 0.2, 1e-9, 'left')
  expect.near(top, 0.1, 1e-9, 'top')
  expect.near(right, 0.6, 1e-9, 'right')
  expect.near(bottom, 0.3, 1e-9, 'bottom')
  local u0, v0, u1, v1 = uvExtent(vertices)
  expect.near(u0, 0.25, 1e-9, 'the crop starts a quarter across')
  expect.near(v0, 0, 1e-9, 'the crop starts at the top')
  expect.near(u1, 0.75, 1e-9, 'the crop is half the texture wide')
  expect.near(v1, 0.5, 1e-9, 'the crop is half the texture high')
end)

test('a child reaching past the window is cut at the window edge, and samples only what remains', function()
  local vertices = children.geometry(PANEL, SQUARE, WINDOW_WIDTH, WINDOW_HEIGHT, child(900, 400, 200, 200))
  assert(vertices, 'the part inside the window is drawn')
  local left, top, right, bottom = extent(vertices)
  expect.near(left, 1.8, 1e-9, 'left')
  expect.near(top, 0.8, 1e-9, 'top')
  expect.near(right, 2, 1e-9, 'cut at the right edge')
  expect.near(bottom, 1, 1e-9, 'cut at the bottom edge')
  local u0, v0, u1, v1 = uvExtent(vertices)
  expect.near(u0, 0, 1e-9, 'u from the left of the texture')
  expect.near(v0, 0, 1e-9, 'v from the top of the texture')
  expect.near(u1, 0.5, 1e-9, 'half the texture is inside the window across')
  expect.near(v1, 0.5, 1e-9, 'half the texture is inside the window down')
end)

test('a child wholly outside the window, or without area, draws nothing', function()
  for _, outside in
    {
      child(1000, 0, 50, 50),
      child(-60, 0, 50, 50),
      child(0, 600, 50, 50),
      child(10, 10, 0, 50),
    }
  do
    expect.equal(children.geometry(PANEL, SQUARE, WINDOW_WIDTH, WINDOW_HEIGHT, outside), nil, 'nothing to draw')
  end
  expect.equal(children.geometry(PANEL, SQUARE, 0, 0, child(0, 0, 10, 10)), nil, 'a window without size')
end)

test("a child in a rounded corner keeps inside the panel's contour", function()
  local rounded = geometry.perimeter({ x = 0, y = 0, width = 2, height = 1 }, geometry.uniform(0.2))
  local vertices = children.geometry(PANEL, rounded, WINDOW_WIDTH, WINDOW_HEIGHT, child(0, 0, 100, 100))
  assert(vertices, 'most of the child is inside')
  local left, top = extent(vertices)
  expect.near(left, 0, 1e-9, 'the child reaches the left edge below the rounding')
  expect.near(top, 0, 1e-9, 'and the top edge beside it')
  for _, vertex in vertices do
    local x, y = vertex[1] + PANEL.width / 2, PANEL.height / 2 - vertex[2]
    expect.falsy(x < 0.01 and y < 0.01, 'the rounded-off corner is not drawn')
  end
end)

test('a child on a curved panel lies on the arc', function()
  local curved = { width = 2, height = 1, curve = 0.5 }
  local vertices = children.geometry(curved, SQUARE, WINDOW_WIDTH, WINDOW_HEIGHT, child(0, 0, 1000, 500))
  assert(vertices, 'the child is drawn')
  local radius = 1 / curved.curve
  for _, vertex in vertices do
    expect.near(vertex[1] ^ 2 + (radius - vertex[3]) ^ 2, radius ^ 2, 1e-9, 'on the cylinder')
  end
end)

return test
