local testing = require '@testing'
local render = require '@testing/render'
local draw = require '../draw'
local laser = require '@lunette-plugins/laser'
local contract = require '@lunette-contracts/laser'
local expect = testing.expect
local test = testing.suite()

local function fixture(hook)
  local native = testing.native()
  local session = testing.start {
    'drops',
    'focus',
    'interaction',
    { id = 'laser', definition = if hook then laser.define { draw = hook } else laser.definition },
  }
  local observer = session:observe(contract.capability)
  local target = observer.service:new(observer.context, 'left', {
    readInput = function()
      return {
        pose = lovr.math.newMat4(),
        origin = vector.pack(0, 0, 0),
        direction = vector.pack(0, 0, -1),
        buttons = {},
        grip = false,
        dt = 1 / 60,
      }
    end,
  })
  target:update {}
  local recorder = render.new()
  recorder.pass:setDepthTest 'gequal'
  recorder.pass:setDepthWrite(true)
  recorder.pass:setColor(0.2, 0.3, 0.4, 0.5)
  recorder.pass:setShader 'caller shader'
  recorder.pass:setMaterial 'caller material'
  return native, target, recorder
end

for _, failure in { false, true } do
  test('laser restores caller state when drawing ' .. (if failure then 'raises' else 'succeeds'), function()
    local _, target, recorder = fixture()
    local caller = recorder:checkpoint()
    if failure then
      recorder.pass.line = function()
        error 'beam failure'
      end
      expect.raises(function()
        draw.laser(target, recorder.pass)
      end, 'beam failure')
    else
      draw.laser(target, recorder.pass)
      for _, call in recorder.calls do
        if call.draw then
          expect.equal(call.state.setDepthTest[1], nil, 'laser is an overlay')
          expect.equal(call.state.setDepthWrite[1], false, 'laser never writes scene depth')
          expect.equal(call.state.setShader[1], nil, 'beam uses its own shader')
          expect.equal(call.state.setMaterial[1], nil, 'beam has no inherited texture')
        end
      end
    end
    recorder:assertRestored(caller)
  end)
end

test('a replacement laser hook restores pass state before its error escapes', function()
  local _, target, recorder = fixture(function(_, pass)
    pass:setDepthTest 'less'
    pass:setDepthWrite(false)
    pass:translate(1, 2, 3)
    error 'hook failure'
  end)
  local caller = recorder:checkpoint()
  expect.raises(function()
    target:draw(recorder.pass)
  end, 'hook failure')
  recorder:assertRestored(caller)
end)

return test
