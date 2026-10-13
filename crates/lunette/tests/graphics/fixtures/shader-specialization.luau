-- Real specialization pipelines remain distinct after parent and clone release/reacquisition.

local testing = require '@testing'
local render = require './support/render'
local test = testing.suite()

local source = [[
  layout(constant_id = 0) const bool red = false;
  vec4 lovrmain() {
    return red ? vec4(1., 0., 0., 1.) : vec4(0., 0., 1., 1.);
  }
]]

test('shader_specialization_lifetime_pixels', function(): ()
  local texture, pass = render.target(16, 8)
  local releases: { Shader } = {}
  local ok, failure = pcall(function(): ()
    for cycle = 1, 64 do
      local parent = lovr.graphics.newShader('fill', source)
      table.insert(releases, parent)
      local red = parent:clone { red = true }
      table.insert(releases, red)
      local blue = parent:clone { red = false }
      table.insert(releases, blue)
      local nested = red:clone { red = false }
      table.insert(releases, nested)
      parent:release()
      table.remove(releases, 1)
      for _, entry in { { red, 1, 0 }, { blue, 0, 1 }, { nested, 0, 1 }, { red, 1, 0 } } do
        pass:reset()
        pass:setCanvas { texture = texture, depth = false, samples = 1 }
        pass:setBlendMode(nil)
        pass:setShader(entry[1])
        pass:fill()
        local image = render.read(texture, pass)
        local r, g, b, a = image:getPixel(8, 4)
        testing.expect.near(r, entry[2], 1 / 255, 'specialized red at cycle ' .. cycle)
        testing.expect.near(g, 0, 1 / 255, 'specialized green at cycle ' .. cycle)
        testing.expect.near(b, entry[3], 1 / 255, 'specialized blue at cycle ' .. cycle)
        testing.expect.near(a, 1, 1 / 255, 'specialized alpha at cycle ' .. cycle)
      end
      pass:reset()
      for _, shader in releases do
        shader:release()
      end
      table.clear(releases)
      -- Submit after release so deferred retirement advances without retaining old shaders.
      lovr.graphics.submit()
    end
    lovr.graphics.wait()
  end)
  for _, shader in releases do
    shader:release()
  end
  pass:release()
  texture:release()
  assert(ok, failure)
end)

return test
