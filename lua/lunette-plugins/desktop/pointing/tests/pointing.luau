local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local surfaces = require '@lunette-contracts/surfaces'
local quad = require '@lunette-contracts/quad'
local vrUi = require '@testing/vr-ui'

local test = testing.suite()

test('the trigger and thumbstick reach a native sink as a primary button and scroll', function()
  local fixture = vrUi.boot {
    'frame',
    'theme',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    {
      id = 'laser',
      definition = require('@lunette-plugins/laser').definition,
      config = { aim = { enabled = false }, triggerLock = { enabled = false } },
    },
    'keyboard',
    'desktop/pointing',
  }
  local window = fixture.native.newWindow(17)
  local pose = lovr.math.newMat4():translate(0, 1.5, -2)
  fixture.session:use(plugin.define {
    name = 'testing/native-sink',
    requires = { surfaces = surfaces.capability },
    init = function(context)
      local target =
        { dead = false, grabbable = false, pose = pose, width = 2, height = 1, pixelWidth = 200, pixelHeight = 100 }
      function target:raycast(origin, direction)
        return quad.hit(self, origin, direction)
      end
      function target:project(origin, direction)
        return quad.project(self, origin, direction)
      end
      function target:sink()
        return window.sink
      end
      context:require(surfaces.capability):offer(context, {
        name = 'native-sink',
        list = function()
          return { target }
        end,
      })
    end,
  })
  local description = {
    visible = true,
    pose = { pose:unpack(true) },
    width = 2,
    height = 1,
    logicalWidth = 200,
    logicalHeight = 100,
  }
  fixture:aim(description, 80, 50, 'right')
  fixture:step()
  fixture:button('right', 'trigger', true)
  fixture:step()
  fixture:axis('right', 0.5, 0.75)
  fixture:step()
  fixture:button('right', 'trigger', false)
  fixture:step()
  local buttons, scrolls = {}, 0
  for _, event in fixture.native.events.input do
    if event[1] == 'button' then
      buttons[#buttons + 1] = event
    elseif event[1] == 'scroll' then
      scrolls += 1
    end
  end
  expect.equal(#buttons, 2, 'one native press and release')
  expect.equal(buttons[1][2], 'left', 'the trigger maps to the primary pointer button')
  expect.equal(buttons[1][3], true, 'the press')
  expect.equal(buttons[2][3], false, 'the release')
  expect.truthy(scrolls > 0, 'native scaled scroll')
  fixture:close()
end)

return test
