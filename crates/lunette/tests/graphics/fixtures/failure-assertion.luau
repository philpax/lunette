-- Leaves submitted GPU objects reachable while the suite reports a failure.

local testing = require '@testing'
local render = require './support/render'
local test = testing.suite()

local texture, pass, shader = render.baseline()
_G.graphicsFailureObjects = { texture, pass, shader }
package.loaded.graphicsFailureObjects = _G.graphicsFailureObjects

test('an assertion failure reaches the Rust runner', function()
  local image = render.read(texture, pass)
  local red = image:getPixel(0, 0)
  testing.expect.near(red, 1, 1 / 255, 'deliberate pixel assertion failure')
end)

return test
