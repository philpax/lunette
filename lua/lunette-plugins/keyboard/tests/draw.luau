local testing = require '@testing'
local render = require '@testing/render'
local keyboard = require '@lunette-plugins/keyboard'
local contract = require '@lunette-contracts/keyboard'
local theme = require '@lunette-contracts/theme'
local expect = testing.expect
local test = testing.suite()

local function fixture(hook, fileFont)
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
          font = if fileFont then { kind = 'file', file = 'keyboard.ttf' } else nil,
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
  local observedTheme = session:observe(theme.capability)
  return board, recorder, { theme = observedTheme.service, owner = observedTheme.context }
end

test('keyboard paints untextured faces and depth-tested legends without writing glyph depth', function()
  local activeStyle
  local board, recorder, env = fixture(function(pass, key, state, base)
    activeStyle = state.style
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
  expect.equal(acquired, 2, 'the board owns one backing mesh and one key-face mesh')
  board:draw(recorder.pass)
  expect.equal(#recorder.meshAcquisitions, acquired, 'unchanged drawing reuses the board meshes')

  local applied = env.theme:select(env.owner, {
    typography = { font = { kind = 'file', file = 'active.ttf', size = 32, spread = 4 }, keyboardLegendHeight = 0.02 },
  })
  board:draw(recorder.pass)
  expect.near(activeStyle.legendHeight, 0.02, 1e-9, 'the same board consumes the updated style')
  expect.equal(#recorder.meshAcquisitions, acquired, 'font changes retain unchanged face geometry')
  recorder:assertRestored(caller)
  applied:dispose()
  board:destroy()
  recorder:assertMeshesReleased()
end)

test('keyboard restores pass state after a hook error', function()
  local board, recorder = fixture(function(pass, _key, state)
    expect.equal(pass:getFont(), state.style.font, 'custom hooks measure with the theme face')
    pass:translate(1, 2, 3)
    pass:setDepthTest()
    error 'keyboard failure'
  end, true)
  local caller = recorder:checkpoint()
  expect.raises(function()
    board:draw(recorder.pass)
  end, 'keyboard failure')
  recorder:assertRestored(caller)
  board:destroy()
  recorder:assertMeshesReleased()
end)

return test
