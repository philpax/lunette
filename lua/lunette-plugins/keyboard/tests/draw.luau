local testing = require '@testing'
local render = require '@testing/render'
local keyboard = require '@lunette-plugins/keyboard'
local contract = require '@lunette-contracts/keyboard'
local expect = testing.expect
local test = testing.suite()

local function fixture(hook)
  testing.native()
  local session = testing.start {
    'drops',
    'focus',
    'interaction',
    {
      id = 'keyboard',
      definition = keyboard.define {
        rows = { { { action = { kind = 'text', text = 'a' }, label = 'A' } } },
        drawKey = hook,
      },
    },
  }
  local observer = session:observe(contract.capability)
  local board = observer.service:new(observer.context)
  local recorder = render.new()
  recorder.pass:setShader 'scene shader'
  recorder.pass:setMaterial 'scene texture'
  recorder.pass:setDepthTest 'gequal'
  recorder.pass:setDepthWrite(true)
  recorder.pass:setColor(0.2, 0.3, 0.4, 0.5)
  return board, recorder
end

test('keyboard paints untextured faces and depth-tested legends without writing glyph depth', function()
  local board, recorder = fixture()
  local caller = recorder:checkpoint()
  board:draw(recorder.pass)
  local faces, legends = 0, 0
  for _, call in recorder.calls do
    if call.draw then
      expect.equal(call.state.setShader[1], nil, 'no inherited shader')
      expect.equal(call.state.setMaterial[1], nil, 'no inherited texture')
      expect.equal(call.state.setDepthTest[1], 'gequal', 'scene depth remains reversed')
      if call[1] == 'text' then
        legends += 1
        expect.equal(call.state.setDepthWrite[1], false, 'transparent glyph bounds do not write depth')
      elseif call[1] == 'plane' then
        faces += 1
        expect.equal(call.state.setDepthWrite[1], true, 'faces retain scene occlusion')
      end
    end
  end
  expect.equal(faces, 2)
  expect.equal(legends, 1)
  recorder:assertRestored(caller)
end)

for _, failure in { 'text', 'hook' } do
  test('keyboard restores pass state after a ' .. failure .. ' error', function()
    local board, recorder = fixture(if failure == 'hook'
      then function(pass)
        pass:translate(1, 2, 3)
        pass:setDepthTest()
        error 'keyboard failure'
      end
      else nil)
    if failure == 'text' then
      recorder.pass.text = function()
        error 'keyboard failure'
      end
    end
    local caller = recorder:checkpoint()
    expect.raises(function()
      board:draw(recorder.pass)
    end, 'keyboard failure')
    recorder:assertRestored(caller)
  end)
end

return test
