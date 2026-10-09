local testing = require '@testing'
local provider = require '@lunette-plugins/panels'
local contract = require '@lunette-contracts/panels'
local expect = testing.expect
local test = testing.suite()

local function fixture(config)
  local native = testing.native()
  local shaders = {}
  lovr.graphics.newShader = function(vertex, fragment)
    local shader = { vertex = vertex, fragment = fragment, released = false }
    function shader:release()
      self.released = true
    end
    shaders[#shaders + 1] = shader
    return shader
  end
  local session = testing.start {
    { id = 'theme', definition = require('@lunette-plugins/theme').definition },
    { id = 'panels', definition = provider.definition, config = config },
  }
  local observer = session:observe(contract.capability)
  local window = native.newWindow(1)
  window.getTexture = function()
    return { name = 'desktop pixels' }
  end
  return native, session, observer, window, shaders
end

test('default windows draw in the scene without claiming post-composite layers', function()
  local native, _, observer, window = fixture()
  local panel = observer.service:fromWindow(observer.context, window)
  panel:update()
  expect.equal(#native.events.claims, 0)
  expect.falsy(panel.granted)
  panel:draw(native.events.pass)
  local planes = 0
  for _, call in native.events.draw do
    if call[1] == 'plane' then
      planes += 1
    end
  end
  expect.equal(planes, 1)
end)

test('opt-in window layers skip scene content only while their claim is granted', function()
  local native, session, observer, window = fixture { rendering = 'layer' }
  local theme = session:observe(require('@lunette-contracts/theme').capability)
  local selected = theme.service:select(theme.context, { radii = { window = 0.2 } })
  local panel = observer.service:fromWindow(observer.context, window)
  expect.equal(#native.events.claims, 1)
  panel.claim.granted = true
  panel.claim.layer = {
    setViewport = function() end,
    setPosition = function() end,
    setOrientation = function() end,
    setDimensions = function() end,
    setCurve = function() end,
  }
  panel:update()
  panel:draw(native.events.pass)
  for _, call in native.events.draw do
    expect.falsy(call[1] == 'plane' or call[1] == 'draw', 'no duplicate content')
  end
  local origin = vector.pack(-panel.width / 2 + 0.001, panel.height / 2 - 0.001, 1)
  expect.truthy(panel:raycast(origin, vector.pack(0, 0, -1)), 'granted content retains rectangular corner hits')
  selected:update { radii = { window = 0.3 } }
  panel:update()
  expect.equal(#native.events.claims, 1, 'radius changes do not churn layer claims')
  panel.claim.granted = false
  panel:update()
  panel:draw(native.events.pass)
  local painted = false
  for _, call in native.events.draw do
    painted = painted or call[1] == 'draw'
  end
  expect.truthy(painted, 'refused layers fall back to rounded scene rendering')
  expect.falsy(panel:raycast(origin, vector.pack(0, 0, -1)), 'the ungranted scene cutout is not pickable')
  selected:dispose()
end)

test('monitor and translucent window planes use colour shaders and restore inherited state', function()
  local native, session, observer, window, shaders = fixture()
  local monitor = native.newMonitor 'display-1'
  monitor.getTexture = window.getTexture
  local translucent = observer.service:fromWindow(observer.context, window, { windowRadius = 0.1 })
  local mirror = observer.service:fromMonitor(observer.context, monitor, { monitorRadius = 0.1 })
  local pass, recorder = native.events.pass, native.events.render
  pass:setShader 'caller shader'
  pass:setMaterial 'caller material'
  pass:setBlendMode('add', 'premultiplied')
  pass:setColor(0.2, 0.4, 0.6, 0.8)
  local caller = recorder:checkpoint()
  translucent:draw(pass)
  mirror:draw(pass)
  expect.equal(#shaders, 2, 'opaque and premultiplied colour conversions')
  local emitted = {}
  for _, call in native.events.draw do
    if call[1] == 'draw' then
      local shader = call.state.setShader[1]
      expect.truthy(shader and shader.fragment:find('gammaToLinear', 1, true), 'encoded pixels are decoded')
      expect.equal(call.state.setBlendMode[1], 'alpha')
      expect.equal(call.state.setBlendMode[2], 'premultiplied')
      emitted[#emitted + 1] = shader
    end
  end
  expect.equal(#emitted, 2)
  expect.truthy(emitted[1] ~= emitted[2], 'monitor padding alpha is forced opaque')
  recorder:assertRestored(caller)
  session:close()
  for _, shader in shaders do
    expect.truthy(shader.released)
  end
end)

return test
