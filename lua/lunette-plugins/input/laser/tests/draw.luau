local testing = require '@testing'
local render = require '@testing/render'
local draw = require '../private/draw'
local laser = require '../'
local contract = require '@lunette-contracts/laser'
local theme = require '@lunette-contracts/theme'
local expect = testing.expect
local test = testing.suite()

local function fixture(hook: laser.Draw): (testing.Native, laser.Beam, render.Recorder, theme.Theme)
  local native = testing.native()
  local session = testing.start {
    'theme',
    'drops',
    'focus',
    'interaction',
    { id = 'laser', definition = laser.define { draw = hook } },
  }
  local observer = session:observe(contract.capability)
  -- The handle is the provider's record, so the test drives its update and draw directly.
  local target = observer.service:attach(observer.context, {
    readInput = function(): contract.Input
      return {
        pose = lovr.math.newMat4(),
        origin = vector.pack(0, 0, 0),
        direction = vector.pack(0, 0, -1),
        buttons = {},
        grip = false,
        dt = 1 / 60,
      }
    end,
  })[1]
  -- A mode change after the laser was made reaches its next update.
  local appearance = session:observe(theme.capability)
  appearance.service:setMode 'light'
  target:update {}
  local recorder = render.new()
  recorder.pass:setDepthTest 'gequal'
  recorder.pass:setDepthWrite(true)
  recorder.pass:setColor(0.2, 0.3, 0.4, 0.5)
  recorder.pass:setShader 'caller shader'
  recorder.pass:setMaterial 'caller material'
  return native, target, recorder, appearance.service:current()
end

test('the beam draws as an overlay in the theme colour, and a raising hook leaves the pass restored', function()
  local raising = false
  local _, target, recorder, current = fixture(function(laserTarget: laser.Beam, pass: Pass, base: laser.DrawBase)
    if raising then
      pass:setDepthTest 'less'
      pass:setDepthWrite(false)
      pass:translate(1, 2, 3)
      error 'hook failure'
    end
    base(laserTarget, pass)
  end)
  local caller = recorder:checkpoint()
  draw.laser(target, recorder.pass)
  for _, call in recorder.calls do
    if call.draw then
      expect.equal(call.state.setDepthTest[1], nil, 'laser is an overlay')
      expect.equal(call.state.setDepthWrite[1], false, 'laser never writes scene depth')
      expect.equal(call.state.setMaterial[1], nil, 'beam has no inherited texture')
      expect.equal(call.state.setColor[1], current.colors.muted[1], "beam uses the live theme's muted ink")
    end
  end
  recorder:assertRestored(caller)
  raising = true
  expect.raises(function()
    target:draw(recorder.pass)
  end, 'hook failure')
  recorder:assertRestored(caller)
end)

return test
