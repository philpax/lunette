-- Covers how the panels provider shows a panel: chrome, the shape hooks, visibility overrides, and the arc
-- mesh of a curved panel.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local panelsModule = require '@lunette-plugins/panels'

local test = testing.suite()

-- A panels provider from `definition` over the fake native API, and two consumers of it whose contexts are
-- `owner` and `other`. The fake's graphics module makes meshes, kept in `meshes`.
local function start(definition, config)
  local env = { native = testing.native(), meshes = {} }
  lovr.graphics.newMesh = function(vertexCount)
    local mesh = { vertexCount = vertexCount, released = false }
    function mesh:setVertices(vertices)
      self.vertices = vertices
    end
    function mesh:setIndices(indices)
      self.indices = indices
    end
    function mesh:release()
      self.released = true
    end
    env.meshes[#env.meshes + 1] = mesh
    return mesh
  end
  env.session = testing.start {
    { id = 'panels', definition = definition or panelsModule.definition, config = config },
  }
  local first = env.session:observe(panelsContract.capability)
  env.panels, env.owner = first.service, first.context
  env.other = env.session:observe(panelsContract.capability).context
  return env
end

local function window(env, id)
  local source = env.native.newWindow(id)
  source.getTexture = function()
    return { name = 'texture ' .. id }
  end
  return source
end

-- Draws `panel` on the fake's pass and answers how many times each drawing call was made.
local function drawn(env, panel)
  local draw = env.native.events.draw
  table.clear(draw)
  if panel then
    panel:draw(env.native.events.pass)
  else
    env.panels:draw(env.native.events.pass)
  end
  local counts = {}
  for _, call in draw do
    counts[call[1]] = (counts[call[1]] or 0) + 1
  end
  return counts
end

test("chrome is off unless a panel or the provider's configuration asks for it", function()
  local env = start()
  local plain = env.panels:fromWindow(env.owner, window(env, 1), { height = 1 })
  expect.equal(plain.chrome, false, 'the chrome of a plain panel')
  local counts = drawn(env, plain)
  expect.equal(counts.plane, 1, 'a plain panel draws its content')
  expect.equal(counts.text, nil, 'a plain panel draws no title')
  local framed = env.panels:fromWindow(env.owner, window(env, 2), { height = 1, chrome = true })
  counts = drawn(env, framed)
  expect.equal(counts.plane, 2, 'a panel with chrome draws a border')
  expect.equal(counts.text, 1, 'a panel with chrome draws a title')
  env.session:close()

  env = start(nil, { chrome = true })
  expect.equal(env.panels:fromWindow(env.owner, window(env, 5), { height = 1 }).chrome, true, 'the default')
  local own = env.panels:fromWindow(env.owner, window(env, 6), { height = 1, chrome = false })
  expect.equal(own.chrome, false, "a panel's own option")
  env.session:close()
end)

test('the shape hooks pick a panel and place its layer', function()
  local raycasts, layered = {}, {}
  local env = start(panelsModule.define {
    name = 'shaped-panels',
    shape = {
      raycast = function(target)
        raycasts[#raycasts + 1] = target
        return 1, 2, 3
      end,
      applyLayer = function(target, layer, base)
        layered[#layered + 1] = target
        base(target, layer)
      end,
    },
  })
  local panel = env.panels:fromWindow(env.owner, window(env, 1), { height = 1 })
  expect.equal(panel:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1)), 1, 'the hook answers the pick')
  expect.equal(raycasts[1], panel, 'the panel the hook picked')
  env.panels:update()
  local claim = panel.claim
  expect.truthy(claim and not claim.dead, 'a shown window panel claims a layer')
  local calls = {}
  claim.granted = true
  claim.layer = {
    setViewport = function() end,
    setPosition = function()
      calls[#calls + 1] = 'position'
    end,
    setOrientation = function() end,
    setDimensions = function() end,
    setCurve = function(_, curve)
      calls[#calls + 1] = 'curve ' .. curve
    end,
  }
  env.panels:update()
  expect.truthy(panel.granted, 'the panel on its granted layer')
  expect.equal(layered[1], panel, 'the panel the hook placed')
  expect.truthy(table.find(calls, 'curve 0') and table.find(calls, 'position'), 'the default placed it flat')
  expect.equal(drawn(env, panel).plane, nil, 'a panel on a layer is not drawn in the scene')
  env.session:close()
end)

test('an override hides a panel, and the most recent live override decides', function()
  local env = start()
  local panel = env.panels:fromWindow(env.owner, window(env, 1), { height = 1 })
  env.panels:update()
  local claim = panel.claim
  local hiding = panel:setHidden(env.owner, { hidden = true })
  expect.truthy(panel.hidden, 'the hidden panel')
  expect.truthy(claim.dead, 'hiding gives up the claim at once')
  expect.equal(panel:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1)), nil, 'a hidden panel is not picked')
  expect.equal(next(drawn(env)), nil, 'a hidden panel is not drawn')
  env.panels:update()
  expect.equal(panel.claim, nil, 'a hidden panel claims no layer')
  expect.equal(env.panels:forSource { id = 1 }, panel, 'a hidden panel stays in the registry')

  local showing = panel:setHidden(env.other, { hidden = false })
  expect.falsy(panel.hidden, 'the newer override shows the panel')
  expect.equal(panel:setHidden(env.owner, { hidden = true }), hiding, 'one override per owner')
  expect.truthy(panel.hidden, 'the moved override is the most recent')
  hiding:dispose()
  expect.falsy(panel.hidden, 'the remaining override shows the panel')
  showing:dispose()
  expect.falsy(panel.hidden, 'with no override the panel is shown')
  env.panels:update()
  expect.truthy(panel.claim and not panel.claim.dead, 'a shown panel claims again')
  expect.raises(function()
    panel:setHidden(env.owner, { hidden = 'yes' })
  end, nil, 'hidden that is not a boolean')

  local doomed = env.panels:fromWindow(env.owner, window(env, 3), { height = 1 })
  local held = doomed:setHidden(env.other, { hidden = true })
  doomed:destroy(env.owner)
  expect.falsy(doomed.hidden, "a panel's end ends its overrides")
  held:dispose()
  env.session:close()
end)

test('a curved panel draws one arc mesh, remade in place on resize and released with the panel', function()
  local env = start()
  local curved = env.panels:fromMonitor(env.owner, {
    id = 'curved',
    name = 'Curved',
    dead = false,
    width = 1600,
    height = 900,
    getTexture = function()
      return { name = 'monitor' }
    end,
  }, { width = 2, curve = 0.5 })
  expect.equal(curved.curve, 0.5, 'the curve')
  local counts = drawn(env, curved)
  expect.equal(counts.draw, 1, 'the arc is drawn as a mesh')
  expect.equal(counts.plane, nil, 'the arc is not drawn as a plane')
  drawn(env, curved)
  expect.equal(#env.meshes, 1, 'the meshes after two draws')
  local mesh = env.meshes[1]
  expect.equal(#mesh.vertices, mesh.vertexCount, 'the vertices of the mesh')
  expect.truthy(#mesh.indices > 0, 'the indices of the mesh')
  local before = mesh.vertices[#mesh.vertices][1]
  curved:setSize(3)
  drawn(env, curved)
  expect.equal(#env.meshes, 1, 'the meshes after the resize')
  expect.truthy(mesh.vertices[#mesh.vertices][1] ~= before, 'the mesh is remade in place')
  curved:destroy(env.owner)
  expect.truthy(mesh.released, 'the mesh is released with the panel')
  for _, curve in { -1, 0 / 0, 'round' } do
    expect.raises(function()
      env.panels:fromWindow(env.owner, window(env, 4), { height = 1, curve = curve })
    end, nil, 'a curve of ' .. tostring(curve))
  end
  env.session:close()
end)

return test
