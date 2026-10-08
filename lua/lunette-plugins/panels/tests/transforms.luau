local testing = require '@testing'
local drawing = require '@lunette-plugins/panels/draw'
local shape = require '@lunette-plugins/panels/shape'
local expect = testing.expect
local test = testing.suite()

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
      local made = {}
      lovr.graphics.newMesh = function()
        local mesh = {}
        function mesh:setVertices(vertices)
          self.vertices = vertices
        end
        function mesh:setIndices(indices)
          self.indices = indices
        end
        made[#made + 1] = mesh
        return mesh
      end
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
      drawing.content(target, native.events.pass, function()
        return nil
      end)
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
  local mesh = { writes = 0 }
  function mesh:setVertices(vertices)
    self.writes += 1
    self.vertices = vertices
  end
  function mesh:setIndices() end
  lovr.graphics.newMesh = function()
    return mesh
  end
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
  drawing.content(target, native.events.pass, function()
    return nil
  end)
  monitor.frameTransform = 'rot90'
  drawing.content(target, native.events.pass, function()
    return nil
  end)
  expect.equal(mesh.writes, 2)
  expect.equal(mesh.vertices[1][7], 0)
  expect.equal(mesh.vertices[1][8], 1)
end)

return test
