local testing = require '@testing'
local drawing = require '@lunette-plugins/panels/draw'
local shape = require '@lunette-plugins/panels/shape'
local expect = testing.expect
local test = testing.suite()

local SQUARE = { windowRadius = 0, monitorRadius = 0 }
local ROUNDED = { windowRadius = 0, monitorRadius = 0.08 }

local function contentShader(): Shader
  return lovr.graphics.newShader('unlit', 'unlit')
end

-- UVs for top-left, top-right, bottom-left, bottom-right from pinned WayVR transform_uv.
local cases = {
  { 'normal', { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } },
  { 'undefined', { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } },
  { 'rot90', { { 0, 1 }, { 0, 0 }, { 1, 1 }, { 1, 0 } } },
  { 'rot180', { { 1, 1 }, { 0, 1 }, { 1, 0 }, { 0, 0 } } },
  { 'rot270', { { 1, 0 }, { 1, 1 }, { 0, 0 }, { 0, 1 } } },
  { 'flipped', { { 1, 0 }, { 0, 0 }, { 1, 1 }, { 0, 1 } } },
  { 'flipped90', { { 0, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 } } },
  { 'flipped180', { { 0, 1 }, { 1, 1 }, { 0, 0 }, { 1, 0 } } },
  { 'flipped270', { { 1, 1 }, { 1, 0 }, { 0, 1 }, { 0, 0 } } },
}

for _, case in cases do
  for _, curve in { 0, 0.4 } do
    test(case[1] .. ' captures draw the WayVR UVs on a ' .. tostring(curve) .. ' curve', function()
      local native = testing.native()
      local made = native.events.render.meshAcquisitions
      local monitor = native.newMonitor 'portrait'
      monitor.frameTransform = case[1]
      monitor.getTexture = function()
        return { name = 'captured pixels' }
      end
      local target = {
        kind = 'monitor',
        source = monitor,
        pose = lovr.math.newMat4(),
        width = 1.08,
        height = 1.92,
        curve = curve,
        highlighted = false,
      }
      drawing.content(target, native.events.pass, SQUARE, contentShader)
      local mesh = made[1]
      if mesh then
        local vertices = mesh.vertices
        local indices = { 1, #vertices - 1, 2, #vertices }
        for corner, index in indices do
          local vertex = vertices[index]
          expect.equal(vertex[7], case[2][corner][1], 'u corner ' .. corner)
          expect.equal(vertex[8], case[2][corner][2], 'v corner ' .. corner)
        end
      else
        expect.truthy(curve == 0 and (case[1] == 'normal' or case[1] == 'undefined'), 'only identity uses a plane')
      end
      drawing.content(target, native.events.pass, ROUNDED, contentShader)
      local rounded = made[#made]
      local tl, tr, bl = case[2][1], case[2][2], case[2][3]
      for _, vertex in rounded.vertices do
        local u = if curve == 0
          then vertex[1] / target.width + 0.5
          else (math.atan2(vertex[1], 1 / curve - vertex[3]) / shape.halfAngle(target.width, curve) + 1) / 2
        local v = 0.5 - vertex[2] / target.height
        expect.near(
          vertex[7],
          tl[1] + u * (tr[1] - tl[1]) + v * (bl[1] - tl[1]),
          1e-9,
          'rounded u preserves source orientation'
        )
        expect.near(
          vertex[8],
          tl[2] + u * (tr[2] - tl[2]) + v * (bl[2] - tl[2]),
          1e-9,
          'rounded v preserves source orientation'
        )
      end
      -- Hit testing stays in logical panel orientation, not transformed texture UVs.
      local u, v = 0.25, 0.75
      local localX = (u - 0.5) * target.width
      if curve > 0 then
        localX = math.sin((2 * u - 1) * shape.halfAngle(target.width, curve)) / curve
      end
      local x, y = shape.hit({
        pose = target.pose,
        width = target.width,
        height = target.height,
        curve = curve,
        pixelWidth = 1080,
        pixelHeight = 1920,
      }, vector.pack(localX, (0.5 - v) * target.height, 2), vector.pack(0, 0, -1))
      expect.near(x, 270, 1e-3, 'logical x tolerates the native vector float precision')
      expect.near(y, 1440, 1e-3, 'logical y tolerates the native vector float precision')
    end)
  end
end

test('a changed capture transform refreshes an existing panel mesh', function()
  local native = testing.native()
  local monitor = native.newMonitor 'display'
  monitor.getTexture = function()
    return {}
  end
  local made = native.events.render.meshAcquisitions
  local target = {
    kind = 'monitor',
    source = monitor,
    pose = lovr.math.newMat4(),
    width = 2,
    height = 1,
    curve = 0.4,
    highlighted = false,
  }
  monitor.frameTransform = 'normal'
  drawing.content(target, native.events.pass, SQUARE, contentShader)
  monitor.frameTransform = 'rot90'
  drawing.content(target, native.events.pass, SQUARE, contentShader)
  expect.equal(#made, 2, 'changed UVs replace the retained mesh')
  expect.truthy(made[1].released, 'the previous transform mesh is released')
  expect.equal(made[2].vertices[1][7], 0)
  expect.equal(made[2].vertices[1][8], 1)
  drawing.content(target, native.events.pass, SQUARE, contentShader)
  expect.equal(#made, 2, 'unchanged capture transforms retain the mesh')
end)

return test
