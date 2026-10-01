-- Visibility overrides, chrome, curves, and the shape hooks.
return function()
  local plugin = require '@lunette-plugin'
  local contracts = require '@lunette-contracts/panels'
  local panelsModule = require '@lunette-plugins/panels'

  local drawn = {}
  local pass = {}
  for _, name in ipairs { 'setBlendMode', 'setShader', 'setMaterial', 'plane', 'setColor', 'text', 'draw' } do
    pass[name] = function(_, ...)
      drawn[#drawn + 1] = { name, ... }
    end
  end
  local function count(name)
    local total = 0
    for _, call in ipairs(drawn) do
      if call[1] == name then
        total += 1
      end
    end
    return total
  end
  local meshes = {}
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
    meshes[#meshes + 1] = mesh
    return mesh
  end

  local function window(id)
    local source = { id = id, dead = false, width = 800, height = 600, title = 'Window ' .. id, opaque = false }
    function source:getTexture()
      return { name = 'texture ' .. id }
    end
    return source
  end

  local raycasts, layered = {}, {}
  local shaped = panelsModule.define {
    name = 'shaped-panels',
    shape = {
      raycast = function(target, origin, direction, backFace, base)
        raycasts[#raycasts + 1] = target
        return 1, 2, 3
      end,
      applyLayer = function(target, layer, base)
        layered[#layered + 1] = target
        base(target, layer)
      end,
    },
  }

  local runtime = plugin.runtime()
  runtime:use(shaped, {}):enable()
  local service, owner, other
  for index, assign in ipairs {
    function(context)
      owner = context
    end,
    function(context)
      other = context
    end,
  } do
    runtime
      :use(
        plugin.define {
          name = 'visibility-' .. index,
          requires = { panels = contracts.capability },
          init = function(context)
            service = context:require(contracts.capability)
            assign(context)
          end,
        },
        {}
      )
      :enable()
  end

  -- Chrome is off unless a panel asks for it.
  local plain = service:fromWindow(owner, window(1), { height = 1 })
  assert(plain.chrome == false and plain.curve == 0 and plain.hidden == false)
  table.clear(drawn)
  plain:draw(pass)
  assert(count 'plane' == 1 and count 'text' == 0 and count 'setColor' == 0, 'a plain panel draws its content only')
  local framed = service:fromWindow(owner, window(2), { height = 1, chrome = true })
  table.clear(drawn)
  framed:draw(pass)
  assert(count 'plane' == 2 and count 'text' == 1, 'a panel with chrome draws a border and a title')
  framed:destroy(owner)

  -- The shape hooks pick and place a layer for every panel.
  assert(plain:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1)) == 1)
  assert(raycasts[1] == plain)
  service:update()
  local claim = plain.claim
  assert(claim and not claim.dead, 'a shown window panel claims a layer')
  local calls = {}
  claim.granted = true
  claim.layer = {
    setViewport = function() end,
    setPosition = function()
      calls[#calls + 1] = 'position'
    end,
    setOrientation = function()
      calls[#calls + 1] = 'orientation'
    end,
    setDimensions = function(_, width, height)
      calls[#calls + 1] = 'dimensions ' .. width .. 'x' .. height
    end,
    setCurve = function(_, curve)
      calls[#calls + 1] = 'curve ' .. curve
    end,
  }
  service:update()
  assert(plain.granted and layered[1] == plain, 'the applyLayer hook placed the layer')
  assert(table.find(calls, 'curve 0') and table.find(calls, 'position'), 'the default placed the layer flat')
  table.clear(drawn)
  plain:draw(pass)
  assert(count 'plane' == 0, 'a panel on a layer is not drawn in the scene')

  -- An owner's override hides the panel: it is not drawn or picked, and its
  -- claim is released at once.
  local hiding = plain:setHidden(owner, { hidden = true })
  assert(plain.hidden and claim.dead and not plain.granted, 'hiding gives up the claim')
  assert(plain:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1)) == nil, 'a hidden panel is not picked')
  table.clear(drawn)
  service:draw(pass)
  assert(#drawn == 0, 'a hidden panel is not drawn')
  service:update()
  assert(plain.claim == nil, 'a hidden panel claims no layer')
  assert(#service:all() == 1 and service:forSource { id = 1 } == plain, 'a hidden panel stays in the registry')

  -- The most recent live override decides, and moving one makes it the most
  -- recent.
  local showing = plain:setHidden(other, { hidden = false })
  assert(not plain.hidden)
  assert(plain:setHidden(owner, { hidden = true }) == hiding, 'one override per owner')
  assert(plain.hidden, 'the moved override is the most recent')
  hiding:dispose()
  assert(not plain.hidden, 'the remaining override shows the panel')
  showing:dispose()
  assert(not plain.hidden, 'with no override the panel is shown')
  service:update()
  assert(plain.claim and not plain.claim.dead, 'a shown panel claims again')
  assert(not pcall(function()
    plain:setHidden(owner, { hidden = 'yes' })
  end), 'hidden is a boolean')
  assert(not pcall(function()
    plain:setHidden(owner, { hidden = true, why = 'test' })
  end), 'an unknown field raises')

  -- An override ends with its owner, and a panel's end ends its overrides.
  local doomed = service:fromWindow(owner, window(3), { height = 1 })
  local held = doomed:setHidden(other, { hidden = true })
  assert(doomed.hidden)
  doomed:destroy(owner)
  assert(doomed.dead and not doomed.hidden)
  held:dispose()

  -- A curved panel draws its arc as a mesh, made once and remade when its
  -- size changes, and released with the panel.
  local curved = service:fromMonitor(owner, {
    id = 'curved',
    name = 'Curved',
    dead = false,
    width = 1600,
    height = 900,
    getTexture = function()
      return { name = 'monitor' }
    end,
  }, { width = 2, curve = 0.5 })
  assert(curved.curve == 0.5)
  table.clear(drawn)
  curved:draw(pass)
  curved:draw(pass)
  assert(#meshes == 1 and count 'draw' == 2 and count 'plane' == 0, 'the arc is one mesh')
  assert(#meshes[1].vertices == meshes[1].vertexCount and #meshes[1].indices > 0)
  curved:setSize(3)
  curved:draw(pass)
  assert(#meshes == 1 and meshes[1].vertices[#meshes[1].vertices][1] ~= 0, 'the mesh is remade in place')
  curved:destroy(owner)
  assert(meshes[1].released, 'the mesh is released with the panel')
  for _, curve in ipairs { -1, 0 / 0, math.huge, 'round' } do
    assert(not pcall(function()
      service:fromWindow(owner, window(4), { height = 1, curve = curve })
    end), 'a curve is a finite number, zero or more: ' .. tostring(curve))
  end

  runtime:close()
  assert(plain.dead)

  -- The provider's chrome option is the default for every panel, and a
  -- panel's own option overrides it.
  runtime = plugin.runtime()
  runtime:use(panelsModule.definition, { chrome = true }):enable()
  runtime
    :use(
      plugin.define {
        name = 'visibility-3',
        requires = { panels = contracts.capability },
        init = function(context)
          service, owner = context:require(contracts.capability), context
        end,
      },
      {}
    )
    :enable()
  assert(service:fromWindow(owner, window(5), { height = 1 }).chrome == true)
  assert(service:fromWindow(owner, window(6), { height = 1, chrome = false }).chrome == false)
  runtime:close()
end
