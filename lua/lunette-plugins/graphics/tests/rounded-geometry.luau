local testing = require '@testing'
local expect = testing.expect

local geometry = require '../rounded-geometry'

local test = testing.suite()

-- The text key that packed keys replaced; it defines which inputs share a cached mesh.
local function textKey(
  bounds: geometry.Bounds,
  given: geometry.Profile,
  clip: geometry.Bounds?,
  thickness: number?
): string
  local profile = geometry.profile(bounds, given)
  local values = {
    bounds.x,
    bounds.y,
    bounds.width,
    bounds.height,
    profile.topLeft.x,
    profile.topLeft.y,
    profile.topRight.x,
    profile.topRight.y,
    profile.bottomRight.x,
    profile.bottomRight.y,
    profile.bottomLeft.x,
    profile.bottomLeft.y,
    thickness or 0,
  }
  if clip then
    for _, value in { clip.x, clip.y, clip.width, clip.height } do
      values[#values + 1] = value
    end
  end
  local parts = {}
  for _, value in values do
    parts[#parts + 1] = string.format('%.17g', value)
  end
  return table.concat(parts, ' ')
end

local function bounds(x: number, y: number, width: number, height: number): geometry.Bounds
  return { x = x, y = y, width = width, height = height }
end

local function profile(tl: number, tr: number, br: number, bl: number): geometry.Profile
  return {
    topLeft = { x = tl, y = tl },
    topRight = { x = tr, y = tr },
    bottomRight = { x = br, y = br },
    bottomLeft = { x = bl, y = bl },
  }
end

type Case = { bounds: geometry.Bounds, profile: geometry.Profile, clip: geometry.Bounds?, thickness: number? }

-- A deterministic generator over a small value set, so that distinct cases often collide and the equal case is exercised.
local function cases(count: number): { Case }
  local state = 12345
  local function pick(values: { number }): number
    state = (state * 1103515245 + 12345) % 2147483648
    return values[state % #values + 1]
  end
  local positions = { 0, -0, 0.25, 1 / 3, 2 }
  local sizes = { 1, 2, 0.5 }
  local radii = { 0, 0.1, 0.25, 0.5, 4 }
  local result: { Case } = {}
  for _ = 1, count do
    local clip = if pick { 0, 1 } == 1 then bounds(pick(positions), pick(positions), pick(sizes), pick(sizes)) else nil
    result[#result + 1] = {
      bounds = bounds(pick(positions), pick(positions), pick(sizes), pick(sizes)),
      profile = profile(pick(radii), pick(radii), pick(radii), pick(radii)),
      clip = clip,
      thickness = if pick { 0, 1 } == 1 then pick { 0, 0.02 } else nil,
    }
  end
  return result
end

test('packed keys match exactly when the text keys matched', function()
  local all = cases(160)
  for first = 1, #all do
    for second = first, #all do
      local a, b = all[first], all[second]
      local text = textKey(a.bounds, a.profile, a.clip, a.thickness)
        == textKey(b.bounds, b.profile, b.clip, b.thickness)
      local packed = geometry.key(a.bounds, a.profile, a.clip, a.thickness)
        == geometry.key(b.bounds, b.profile, b.clip, b.thickness)
      expect.equal(packed, text, `cases {first} and {second}`)
    end
  end
end)

test('radii beyond half the bounds share the key of the clamped radius', function()
  local area = bounds(0, 0, 1, 1)
  expect.equal(geometry.key(area, profile(4, 0, 0, 0)), geometry.key(area, profile(0.5, 0, 0, 0)))
end)

test('the sign of zero distinguishes keys', function()
  expect.falsy(
    geometry.key(bounds(0, 0, 1, 1), profile(0, 0, 0, 0)) == geometry.key(bounds(-0, 0, 1, 1), profile(0, 0, 0, 0))
  )
end)

test('a missing thickness keys like zero and a clip always changes the key', function()
  local area, corners = bounds(0, 0, 1, 1), profile(0.1, 0.1, 0.1, 0.1)
  expect.equal(geometry.key(area, corners, nil, nil), geometry.key(area, corners, nil, 0))
  expect.falsy(geometry.key(area, corners) == geometry.key(area, corners, bounds(0, 0, 1, 1)))
end)

return test
