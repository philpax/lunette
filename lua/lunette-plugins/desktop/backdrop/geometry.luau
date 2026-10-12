-- Fixed indexed surfaces; curtain displacement and shading stay on the GPU.
local config = require './config'

local geometry = {}
export type Data = { read vertices: { { number } }, read indices: { number } }
export type Surfaces = { read sky: Data, read curtain: Data }

local tessellation = {
  low = { segments = 64, vertical = 6 },
  standard = { segments = 128, vertical = 8 },
  high = { segments = 192, vertical = 12 },
}
local grid: (number, number, (number, number) -> vector) -> Data

function geometry.build(settings: config.Settings): Surfaces
  local quality = tessellation[settings.quality]
  local sky = grid(quality.segments, 24, function(u: number, v: number): vector
    local longitude, latitude = u * 2 * math.pi, (v - 0.5) * math.pi
    local radial = math.cos(latitude) * settings.distance
    return vector.pack(
      math.sin(longitude) * radial,
      math.sin(latitude) * settings.distance,
      math.cos(longitude) * radial
    )
  end)
  local curtain = grid(quality.segments, quality.vertical, function(_u: number, _v: number): vector
    -- The shader derives the position from UV; the default position remains finite for CPU inspection.
    return vector.pack(0, 0, 0)
  end)
  return { sky = sky, curtain = curtain }
end

grid = function(segments: number, vertical: number, position: (number, number) -> vector): Data
  local vertices: { { number } } = {}
  local indices: { number } = {}
  for row = 0, vertical do
    local v = row / vertical
    for column = 0, segments do
      local u = column / segments
      local point = position(u, v)
      vertices[#vertices + 1] = { point.x, point.y, point.z, 0, 1, 0, u, v }
    end
  end
  for row = 0, vertical - 1 do
    for column = 0, segments - 1 do
      local a = row * (segments + 1) + column + 1
      local b, c, d = a + 1, a + segments + 1, a + segments + 2
      for _, index in { a, c, b, b, c, d } do
        indices[#indices + 1] = index
      end
    end
  end
  return { vertices = vertices, indices = indices }
end

return geometry
