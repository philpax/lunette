local testing = require '@testing'
local render = require '@testing/render'
local keyboard = require '@lunette-plugins/keyboard'
local contract = require '@lunette-contracts/keyboard'
local expect = testing.expect
local test = testing.suite()

local function fixture(hook)
  testing.native()
  local session = testing.start {
    'theme',
    'drops',
    'focus',
    'interaction',
    {
      id = 'keyboard',
      definition = keyboard.define {
        rows = { { { action = { kind = 'text', text = 'a' }, label = 'A' } } },
        drawKey = hook,
        style = {
          backingRadius = 0.008,
          keyRadius = 0.012,
        },
      },
    },
  }
  local observer = session:observe(contract.capability)
  local board = observer.service:new(observer.context)
  local recorder = render.new()
  lovr.graphics.newMesh = function(count)
    return recorder:newMesh(count)
  end
  recorder.pass:setShader 'scene shader'
  recorder.pass:setMaterial 'scene texture'
  recorder.pass:setDepthTest 'gequal'
  recorder.pass:setDepthWrite(true)
  recorder.pass:setColor(0.2, 0.3, 0.4, 0.5)
  return board, recorder
end

test('keyboard paints untextured faces and depth-tested legends, and restores the pass after a hook error', function()
  local raising = false
  local board, recorder = fixture(function(pass, key, state, base)
    if raising then
      pass:translate(1, 2, 3)
      error 'keyboard failure'
    end
    expect.equal(pass:getFont(), state.style.font, 'the hook receives the theme face')
    base(pass, key, state)
  end)
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
      elseif call[1] == 'draw' then
        faces += 1
        expect.equal(call.state.setDepthWrite[1], true, 'faces retain scene occlusion')
      end
    end
  end
  expect.equal(faces, 2)
  expect.equal(legends, 1)
  recorder:assertRestored(caller)
  local acquired = #recorder.meshAcquisitions
  board:draw(recorder.pass)
  expect.equal(#recorder.meshAcquisitions, acquired, 'unchanged drawing reuses the board meshes')
  raising = true
  expect.raises(function()
    board:draw(recorder.pass)
  end, 'keyboard failure')
  recorder:assertRestored(caller)

  board:destroy()
  recorder:assertMeshesReleased()
end)

return test
