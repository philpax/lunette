-- A plugin written as a user would write one, given no configuration, draws in
-- the shipped desktop and offers a surface its lasers pick.
local plugin = require '@lunette-plugin'
local frameContract = require '@lunette-contracts/frame'
local surfacesContract = require '@lunette-contracts/surfaces'
local quad = require '@lunette-contracts/quad'

local desktop = require 'fixture/graph'()
local drawn, pressed = 0, 0
local pose = lovr.math.newMat4():translate(0, 1.5, -1)
local hud = {
  dead = false,
  grabbable = false,
  width = 0.2,
  height = 0.2,
  pose = pose,
  raycast = function(_self, origin, direction)
    return quad.hit(
      { pose = pose, width = 0.2, height = 0.2, pixelWidth = 1, pixelHeight = 1, backFace = true },
      origin,
      direction
    )
  end,
  onPress = function()
    pressed += 1
  end,
}
local instance = desktop.runtime:use(
  plugin.define {
    name = 'user-hud',
    requires = { frame = frameContract.capability, surfaces = surfacesContract.capability },
    init = function(ctx, _config: {})
      local frameService = ctx:require(frameContract.capability)
      local broker = ctx:require(surfacesContract.capability)
      broker:offer(ctx, {
        name = 'user-hud',
        list = function()
          return { hud }
        end,
      })
      frameService:onDraw(ctx, {
        phase = 'overlay',
        run = function(pass)
          drawn += 1
          pass:text('hud', pose, 0, 'center', 'middle')
        end,
      })
    end,
  },
  {}
)
instance:enable()
assert(instance:state() == 'active', tostring(instance:diagnostic()))

local found = false
for _, candidate in ipairs(desktop.surfaces:all()) do
  found = found or candidate == hud
end
assert(found, 'the user offer is among the desktop surfaces')

events.draw = {}
lovr.update(0.016)
assert(lovr.draw(events.pass) == false)
assert(drawn == 1, 'the user draw handler ran in the shipped frame')
local hudText = false
for _, call in ipairs(events.draw) do
  hudText = hudText or (call[1] == 'text' and call[2] == 'hud')
end
assert(hudText)

instance:disable()
lovr.draw(events.pass)
assert(drawn == 1, 'the user draw handler ends with the plugin')
for _, candidate in ipairs(desktop.surfaces:all()) do
  assert(candidate ~= hud, 'the user offer ends with the plugin')
end
assert(lovr.quit() == false)
