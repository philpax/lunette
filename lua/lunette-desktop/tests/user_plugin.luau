-- Covers a plugin written as a user would write one, given no configuration: in the shipped desktop it
-- draws, offers a surface the lasers pick, and both end with it.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local frameContract = require '@lunette-contracts/frame'
local surfacesContract = require '@lunette-contracts/surfaces'
local quad = require '@lunette-contracts/quad'

local test = testing.suite()

test('a user plugin draws and offers a surface in the shipped desktop until it unloads', function()
  local session = testing.boot(desktop.entries())
  local events = session.native.events
  local surfaces = session:observe(surfacesContract.capability)
  local drawn = 0
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
  }
  local instance = session:use(plugin.define {
    name = 'user-hud',
    requires = { frame = frameContract.capability, surfaces = surfacesContract.capability },
    init = function(context, _config: {})
      context:require(surfacesContract.capability):offer(context, {
        name = 'user-hud',
        list = function()
          return { hud }
        end,
      })
      context:require(frameContract.capability):onDraw(context, {
        phase = 'overlay',
        run = function(pass)
          drawn += 1
          pass:text('hud', pose, 0, 'center', 'middle')
        end,
      })
    end,
  })
  expect.equal(instance:state(), 'active', 'the user plugin')
  expect.truthy(table.find(surfaces.service:all(), hud), 'the user offer is among the desktop surfaces')

  session:update()
  expect.equal(session:draw(), false, 'draw does not veto')
  expect.equal(drawn, 1, 'the user draw handler runs in the shipped frame')
  local hudText = false
  for _, call in ipairs(events.draw) do
    hudText = hudText or (call[1] == 'text' and call[2] == 'hud')
  end
  expect.truthy(hudText, 'the user plugin draws into the pass')

  instance:disable()
  session:draw()
  expect.equal(drawn, 1, 'the user draw handler ends with the plugin')
  expect.falsy(table.find(surfaces.service:all(), hud), 'the user offer ends with the plugin')
  session:close()
end)

return test
