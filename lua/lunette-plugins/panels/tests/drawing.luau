local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/panels'
local drawing = require '@lunette-plugins/panels/draw'

local test = testing.suite()

local function start(config)
  local native = testing.native()
  local session = testing.start {
    'theme',
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = config },
  }
  local observed = session:observe(contract.capability)
  local window = native.newWindow(1)
  window.getTexture = function()
    return {
      name = 'desktop pixels',
      getDimensions = function()
        return 2000, 1000
      end,
    }
  end
  return native, session, observed.service, observed.context, window
end

local function grantLayer(panel, viewports)
  panel.claim.granted = true
  panel.claim.layer = {
    setViewport = function(_, x, y, width, height)
      viewports[#viewports + 1] = { x, y, width, height }
    end,
    setPosition = function() end,
    setOrientation = function() end,
    setDimensions = function() end,
    setCurve = function() end,
  }
end

local function drawn(native, panel)
  table.clear(native.events.draw)
  panel:draw(native.events.pass)
  local counts = {}
  for _, call in native.events.draw do
    counts[call[1]] = (counts[call[1]] or 0) + 1
  end
  return counts
end

test('a window draws in the scene by default, and skips it only while an opted-in layer is granted', function()
  local native, session, panels, owner, window = start()
  local plain = panels:fromWindow(owner, window)
  expect.equal(#native.events.claims, 0, 'the default claims no layer')
  expect.equal(drawn(native, plain).plane, 1, 'the content plane')
  session:close()

  native, session, panels, owner, window = start { rendering = 'layer' }
  local layered = panels:fromWindow(owner, window)
  expect.equal(#native.events.claims, 1, 'the opted-in claim')
  grantLayer(layered, {})
  layered:update()
  local granted = drawn(native, layered)
  expect.falsy(granted.plane or granted.draw, 'a granted layer draws no scene content')
  layered.claim.granted = false
  layered:update()
  local refused = drawn(native, layered)
  expect.truthy(refused.plane or refused.draw, 'a refused layer falls back to the scene')
  session:close()
end)

test('content decodes its colour and restores the pass state it inherited', function()
  local native, session, panels, owner, window = start()
  local panel = panels:fromWindow(owner, window)
  local pass, recorder = native.events.pass, native.events.render
  pass:setShader 'caller shader'
  pass:setColor(0.2, 0.4, 0.6, 0.8)
  local caller = recorder:checkpoint()
  table.clear(native.events.draw)
  panel:draw(pass)
  local shader
  for _, call in native.events.draw do
    shader = shader or (call[1] == 'draw' or call[1] == 'plane') and call.state.setShader[1]
  end
  expect.truthy(shader and shader.fragment:find('gammaToLinear', 1, true), 'encoded pixels are decoded')
  recorder:assertRestored(caller)
  session:close()
end)

test('chrome draws a ring and title in theme colours when a panel or the configuration asks', function()
  local native, session, panels, owner, window = start()
  expect.equal(drawn(native, panels:fromWindow(owner, window, { height = 1 })).text, nil, 'no chrome by default')
  local theme = session:observe(require('@lunette-contracts/theme').capability)
  local selected = theme.service:select(theme.context, { colors = { foreground = { 0.8, 0.7, 0.6, 1 } } })
  local framed = panels:fromWindow(owner, native.newWindow(2), { height = 1, chrome = true })
  drawn(native, framed)
  local title
  for _, call in native.events.draw do
    title = if call[1] == 'text' then call else title
  end
  expect.equal(title.state.setColor[1], 0.8, 'the title inherits the foreground')
  selected:dispose()
  session:close()

  native, session, panels, owner, window = start { chrome = true }
  expect.equal(panels:fromWindow(owner, window, { height = 1 }).chrome, true, 'the configured default')
  expect.equal(panels:fromWindow(owner, native.newWindow(2), { chrome = false }).chrome, false, "a panel's own option")
  session:close()
end)

test('a cropped window samples only its crop in the scene', function()
  local native, session, panels, owner, window = start()
  local panel = panels:fromWindow(owner, window)
  local made = native.events.render.meshAcquisitions
  expect.equal(drawn(native, panel).plane, 1, 'an uncropped window draws a plain quad')

  window.sourceCrop = { 0.25, 0.5, 0.5, 0.25 }
  local counts = drawn(native, panel)
  expect.equal(counts.draw, 1, 'a cropped window draws a mesh')
  local vertices = made[#made].vertices
  local corners = { { 0.25, 0.5 }, { 0.75, 0.5 }, { 0.25, 0.75 }, { 0.75, 0.75 } }
  for corner, index in { 1, 3, 2, 4 } do
    expect.equal(vertices[index][7], corners[corner][1], 'u of corner ' .. corner)
    expect.equal(vertices[index][8], corners[corner][2], 'v of corner ' .. corner)
  end

  drawn(native, panel)
  expect.equal(#made, 1, 'an unchanged crop keeps its mesh')
  window.sourceCrop = { 0, 0, 0.5, 1 }
  drawn(native, panel)
  expect.equal(#made, 2, 'a changed crop replaces the mesh')
  session:close()
end)

test('a layer is claimed at the texture size and shows only the crop', function()
  local native, session, panels, owner, window = start { rendering = 'layer' }
  window.width, window.height = 1000, 500
  local panel = panels:fromWindow(owner, window)
  local claim = native.events.claims[1]
  expect.equal(claim.width, 2000, 'the claim holds the whole texture across')
  expect.equal(claim.height, 1000, 'the claim holds the whole texture down')

  local viewports = {}
  grantLayer(panel, viewports)
  panel:update()
  expect.equal(table.concat(viewports[1], ' '), '0 0 2000 1000', 'an uncropped window shows the whole texture')

  window.sourceCrop = { 0.25, 0.5, 0.5, 0.25 }
  panel:update()
  expect.equal(table.concat(viewports[2], ' '), '500 500 1000 250', 'a cropped window shows its crop')
  panel:update()
  expect.equal(#viewports, 2, 'an unchanged crop sets no viewport again')
  session:close()
end)

-- UVs for top-left, top-right, bottom-left, and bottom-right from pinned WayVR transform_uv.
local TRANSFORMS = {
  { 'normal', { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } },
  { 'rot90', { { 0, 1 }, { 0, 0 }, { 1, 1 }, { 1, 0 } } },
  { 'rot180', { { 1, 1 }, { 0, 1 }, { 1, 0 }, { 0, 0 } } },
  { 'rot270', { { 1, 0 }, { 1, 1 }, { 0, 0 }, { 0, 1 } } },
  { 'flipped', { { 1, 0 }, { 0, 0 }, { 1, 1 }, { 0, 1 } } },
  { 'flipped90', { { 0, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 } } },
  { 'flipped180', { { 0, 1 }, { 1, 1 }, { 0, 0 }, { 1, 0 } } },
  { 'flipped270', { { 1, 1 }, { 1, 0 }, { 0, 1 }, { 0, 0 } } },
}

test('a capture draws the WayVR UVs of its transform, and a changed transform replaces the mesh', function()
  local function shader(): Shader
    return lovr.graphics.newShader('unlit', 'unlit')
  end
  local style = { windowRadius = 0, monitorRadius = 0 }
  local native = testing.native()
  local made = native.events.render.meshAcquisitions
  local monitor = native.newMonitor 'display'
  monitor.getTexture = function()
    return { name = 'captured pixels' }
  end
  local target = { kind = 'monitor', source = monitor, pose = lovr.math.newMat4(), width = 2, height = 1, curve = 0.4 }
  for _, case in TRANSFORMS do
    monitor.frameTransform = case[1]
    drawing.content(target, native.events.pass, style, shader)
    local vertices = made[#made].vertices
    for corner, index in { 1, #vertices - 1, 2, #vertices } do
      expect.equal(vertices[index][7], case[2][corner][1], case[1] .. ': u of corner ' .. corner)
      expect.equal(vertices[index][8], case[2][corner][2], case[1] .. ': v of corner ' .. corner)
    end
  end
  expect.equal(#made, #TRANSFORMS, 'each transform made its own mesh')
  expect.truthy(made[1].released, 'a replaced mesh is released')
end)

return test
