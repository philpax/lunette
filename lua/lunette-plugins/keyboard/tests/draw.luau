local testing = require '@testing'
local render = require '@testing/render'
local keyboard = require '@lunette-plugins/keyboard'
local contract = require '@lunette-contracts/keyboard'
local theme = require '@lunette-contracts/theme'
local themeProvider = require '@lunette-plugins/theme'
local geometry = require '@lunette-plugins/theme/rounded-geometry'
local plugin = require '@lunette-plugin'
local expect = testing.expect
local test = testing.suite()

local function fixture(hook, fileFont)
  local native = testing.native()
  local faces = {}
  local newFont = lovr.graphics.newFont
  lovr.graphics.newFont = function(file, size, spread)
    local face = newFont(file, size, spread)
    faces[#faces + 1] = face
    return face
  end
  local control = { fail = false }
  local definition = plugin.define {
    name = 'keyboard-draw-theme',
    provides = { theme = theme.capability },
    init = function(context, _settings, publish)
      local service = themeProvider.build(context, {})
      local acquire = service.acquireFont
      service.acquireFont = function(self, owner, spec)
        if control.fail then
          error 'keyboard refresh failure'
        end
        return acquire(self, owner, spec)
      end
      publish:provide(theme.capability, service)
    end,
  }
  local session = testing.start {
    { id = 'theme', definition = definition },
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
  return board,
    recorder,
    {
      session = session,
      faces = faces,
      theme = observedTheme.service,
      owner = observedTheme.context,
      control = control,
      native = native,
    }
end

test('keyboard paints untextured faces and depth-tested legends without writing glyph depth', function()
  local trigger = false
  local activeStyle, observed, applied = nil, nil, nil
  local board, recorder, env
  board, recorder, env = fixture(function(pass, key, state, base)
    activeStyle = state.style
    if trigger then
      trigger = false
      applied:update { typography = { font = { kind = 'default' }, keyboardLegendHeight = 0.02 } }
    end
    local width, height = math.max(0, key.width - state.style.gap), math.max(0, key.height - state.style.gap)
    recorder.expectedClip = geometry.safeClip({
      x = -width / 2,
      y = -height / 2,
      width = width,
      height = height,
    }, geometry.uniform(state.style.keyRadius))
    expect.equal(pass:getFont(), state.style.font, 'the hook receives the exact leased face')
    base(pass, key, state)
  end)
  observed = env.theme
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

  applied = observed:select(
    env.owner,
    { typography = { font = { kind = 'file', file = 'active.ttf', size = 32, spread = 4 } } }
  )
  trigger = true
  local start = #recorder.calls
  board:draw(recorder.pass)
  for index = start + 1, #recorder.calls do
    expect.truthy(recorder.calls[index][1] ~= 'text', 'a nested geometry refresh rejects the stale base draw')
  end
  expect.truthy(env.faces[1].released, 'a replaced render face releases after its pinned invocation')
  board:draw(recorder.pass)
  expect.near(activeStyle.legendHeight, 0.02, 1e-9, 'the same board consumes the updated style')

  applied:update {
    typography = { font = { kind = 'file', file = 'retained.ttf', size = 32, spread = 4 }, keyboardLegendHeight = 0.02 },
  }
  board:draw(recorder.pass)
  local retained = env.faces[2]
  expect.equal(#recorder.meshAcquisitions, acquired, 'font changes retain unchanged face geometry')
  for index, call in recorder.calls do
    if call[1] == 'text' then
      local clip = recorder.expectedClip
      recorder:assertBounds({
        x = clip.x,
        y = -(clip.y + clip.height),
        width = clip.width,
        height = clip.height,
        tolerance = 1e-8,
      }, index, index)
    end
  end
  env.control.fail = true
  applied:update { typography = { keyboardLegendHeight = 0.03 } }
  expect.falsy(retained.released, 'failed refresh retains the old lease after its selection hold is removed')
  expect.equal(#env.native.events.reported, 1, 'the listener reports the failed refresh')
  expect.raises(function()
    board:draw(recorder.pass)
  end, 'keyboard refresh failure', 'a later draw retries current revision before using stale geometry')
  expect.near(activeStyle.legendHeight, 0.02, 1e-9, 'failed refresh preserves the old applied state')
  env.control.fail = false
  board:draw(recorder.pass)
  expect.near(activeStyle.legendHeight, 0.03, 1e-9, 'restored acquisition retries the unapplied revision')
  expect.truthy(retained.released, 'successful retry releases the old face only after publishing the new style')
  recorder:assertRestored(caller)
  applied:dispose()
  board:destroy()
  recorder:assertMeshesReleased()
end)

for _, failure in { 'text', 'hook' } do
  test('keyboard restores pass state after a ' .. failure .. ' error', function()
    local board, recorder, env
    board, recorder, env = fixture(
      if failure == 'hook'
        then function(pass, _key, state)
          expect.equal(pass:getFont(), state.style.font, 'custom hooks measure with the leased face')
          board:destroy()
          expect.falsy(env.faces[1].released, 'destruction retains the face during hook unwind')
          pass:translate(1, 2, 3)
          pass:setDepthTest()
          error 'keyboard failure'
        end
        else nil,
      true
    )
    if failure == 'text' then
      recorder.pass.text = function()
        board:destroy()
        expect.falsy(env.faces[1].released, 'destruction retains the face during text unwind')
        error 'keyboard failure'
      end
    end
    local restore = recorder.pass.pop
    recorder.pass.pop = function(self, ...)
      expect.falsy(env.faces[1].released, 'the invocation pins the face through pass restoration')
      restore(self, ...)
    end
    local caller = recorder:checkpoint()
    expect.raises(function()
      board:draw(recorder.pass)
    end, 'keyboard failure')
    recorder:assertRestored(caller)
    expect.truthy(env.faces[1].released, 'the face releases after protected render unwind')
    recorder:assertMeshesReleased()
  end)
end

return test
