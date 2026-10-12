-- Uses the real compiler failure path with already allocated GPU resources.

local testing = require '@testing'
local render = require './support/render'
local test = testing.suite()

local texture, pass, shader = render.baseline()
_G.graphicsFailureObjects = { texture, pass, shader }
package.loaded.graphicsFailureObjects = _G.graphicsFailureObjects

test('a shader compiler error reaches the Rust runner', function()
  lovr.graphics.newShader(
    'fill',
    [[
    vec4 lovrmain() { return deliberate_invalid_shader; }
  ]]
  )
end)

return test
