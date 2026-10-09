local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local panelsModule = require '@lunette-plugins/panels'
local themeContract = require '@lunette-contracts/theme'
local render = require '@testing/render'

local test = testing.suite()

local function start(definition, config, themeDefinition, newFont)
  local env = { native = testing.native(), meshes = {} }
  if newFont then
    lovr.graphics.newFont = newFont
  end
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
    { id = 'theme', definition = themeDefinition or require('@lunette-plugins/theme').definition },
    { id = 'panels', definition = definition or panelsModule.definition, config = config },
  }
  local theme = env.session:observe(themeContract.capability)
  env.theme, env.themeOwner = theme.service, theme.context
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
  local acquisitionFails = false
  local delivered = 0
  local broker = plugin.provider {
    name = 'chrome-theme',
    capability = themeContract.capability,
    build = function(context)
      local real = require('@lunette-plugins/theme').build(context)
      return setmetatable({
        onChanged = function(_, owner, run)
          return real:onChanged(owner, function(snapshot)
            delivered += 1
            run(snapshot)
          end)
        end,
        acquireFont = function(_, owner, spec)
          if acquisitionFails then
            error 'panel font acquisition failure'
          end
          return real:acquireFont(owner, spec)
        end,
      }, { __index = real })
    end,
  }
  local env = start(nil, nil, broker.definition)
  local plain = env.panels:fromWindow(env.owner, window(env, 1), { height = 1 })
  expect.equal(plain.chrome, false, 'the chrome of a plain panel')
  local counts = drawn(env, plain)
  expect.equal(counts.plane, 1, 'a plain panel draws its content')
  expect.equal(counts.text, nil, 'a plain panel draws no title')
  local framed = env.panels:fromWindow(env.owner, window(env, 2), { height = 1, chrome = true })
  counts = drawn(env, framed)
  expect.equal(counts.plane, 1, 'square captured content retains its plane')
  expect.equal(counts.draw, 1, 'a panel with chrome draws an outline ring')
  expect.equal(counts.text, 1, 'a panel with chrome draws a title')

  local faces = {}
  lovr.graphics.newFont = function(file, size, spread)
    local font = render.new().font
    font.file, font.size, font.spread, font.released = file, size, spread, false
    font.getHeight = function()
      assert(not font.released, 'measuring a released font')
      return 2
    end
    font.release = function()
      font.released = true
    end
    faces[#faces + 1] = font
    return font
  end
  local selected = env.theme:select(env.themeOwner, {
    colors = { foreground = { 0.8, 0.7, 0.6, 1 }, border = { 0.1, 0.2, 0.3, 1 }, focus = { 0.4, 0.5, 0.6, 1 } },
    typography = { font = { kind = 'file', file = 'panel-face-a.ttf', size = 24, spread = 3 }, titleHeight = 0.06 },
    metrics = { titlebarBorderThickness = 0.012 },
    radii = { window = 0.03, monitor = 0.04 },
  })
  local pass, recorder = env.native.events.pass, env.native.events.render
  pass:setFont(recorder.font)
  pass:setColor(0.3, 0.2, 0.1, 0.5)
  local caller = recorder:checkpoint()
  counts = drawn(env, framed)
  local function paintCalls()
    local border, title
    for _, call in env.native.events.draw do
      if call[1] == 'draw' and not border then
        border = call
      elseif call[1] == 'text' then
        title = call
      end
    end
    return border, title
  end
  local border, title = paintCalls()
  expect.equal(title.state.setFont[1], faces[1], 'the title draws with the selected face')
  expect.equal(title.state.setColor[1], 0.8, 'the title inherits foreground')
  expect.equal(border.state.setColor[1], 0.1, 'the border inherits border')
  expect.near(title[3]:getScale(), 0.03, 1e-9, 'the selected face measures the title height')
  expect.equal(counts.plane, nil, 'rounded content has no square plane')
  expect.equal(counts.draw, 2, 'rounded captured content and chrome have distinct meshes')
  recorder:assertRestored(caller)
  framed:setHighlighted(true)
  drawn(env, framed)
  border = paintCalls()
  expect.equal(border.state.setColor[1], 0.4, 'the highlight inherits focus')

  selected:update { typography = { font = { kind = 'file', file = 'panel-face-b.ttf', size = 28, spread = 4 } } }
  expect.truthy(faces[1].released, 'the subscription publishes the replacement before dropping old paint')
  acquisitionFails = true
  local beforeRevision = env.theme:current().revision
  selected:update {
    colors = { foreground = { 0.2, 0.3, 0.4, 1 } },
    typography = { font = { kind = 'file', file = 'panel-face-b.ttf', size = 28, spread = 4 } },
  }
  expect.equal(env.theme:current().revision, beforeRevision + 1, 'the palette publishes a new revision')
  expect.equal(delivered, 3, 'one subscription receives each current revision')
  local reports = env.native.events.reported
  expect.equal(#reports, 1, 'the failed subscription refresh is reported')
  expect.truthy(reports[1].message:find('panel font acquisition failure', 1, true), 'the acquisition error')
  expect.raises(function()
    drawn(env, framed)
  end, 'panel font acquisition failure', 'a failed refresh raises')
  expect.falsy(faces[2].released, 'a failed refresh retains the previous paint lease')
  acquisitionFails = false
  drawn(env, framed)
  _, title = paintCalls()
  expect.equal(title.state.setFont[1], faces[2], 'a later draw retries the current revision')
  expect.equal(title.state.setColor[1], 0.2, 'the successful retry publishes the current palette')

  local text = pass.text
  pass.text = function()
    selected:update { typography = { font = { kind = 'file', file = 'panel-face-c.ttf', size = 30, spread = 4 } } }
    env.panels:update()
    expect.falsy(faces[2].released, 'the old draw invocation retains its face through refresh')
    text(pass, 'retained', lovr.math.newMat4(), 0, 'center', 'middle')
    error 'chrome title failure'
  end
  expect.raises(function()
    drawn(env, framed)
  end, 'chrome title failure', 'a failing chrome draw')
  pass.text = text
  recorder:assertRestored(caller)
  expect.truthy(faces[2].released, 'the invocation drops its face after restoration')
  selected:dispose()
  expect.truthy(faces[3].released, 'ending a selection refreshes and releases stale paint')
  framed:raycast(vector.pack(0, 0, 1), vector.pack(0, 0, -1))
  env.session:close()

  local newFont = lovr.graphics.newFont
  env = start(nil, {
    chrome = true,
    style = {
      font = { kind = 'file', file = 'panel-explicit.ttf' },
      windowRadius = 0,
      borderThickness = 0,
      titleColor = { 0.9, 0.1, 0.2, 1 },
    },
  }, nil, newFont)
  local defaultChrome = env.panels:fromWindow(env.owner, window(env, 5), { height = 1 })
  expect.equal(defaultChrome.chrome, true, 'the default')
  local own = env.panels:fromWindow(env.owner, window(env, 6), { height = 1, chrome = false })
  expect.equal(own.chrome, false, "a panel's own option")
  local override = env.theme:select(env.themeOwner, {
    typography = { titleHeight = 0.07 },
    metrics = { titlebarBorderThickness = 0.02 },
    radii = { window = 0.08, monitor = 0.09 },
    colors = { foreground = { 0.3, 0.4, 0.5, 1 } },
  })
  drawn(env, defaultChrome)
  local explicitTitle
  for _, call in env.native.events.draw do
    if call[1] == 'text' then
      explicitTitle = call
    end
  end
  expect.equal(explicitTitle.state.setFont[1], faces[#faces], 'explicit provider font wins')
  expect.equal(explicitTitle.state.setColor[1], 0.9, 'explicit provider title colour wins')
  local square = drawn(env, defaultChrome)
  expect.equal(square.plane, 1, 'an explicit zero provider radius survives a theme change')
  expect.equal(square.draw, nil, 'an explicit zero border survives a theme change')
  override:dispose()
  env.session:close()
  expect.truthy(faces[#faces].released, 'shutdown releases the explicit provider font')
end)

test('an override hides a panel, and the most recent live override decides', function()
  local env = start(nil, { rendering = 'layer' })
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

test('a curved panel retains one arc mesh, replaced on resize and released with the panel', function()
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
  expect.equal(#env.meshes, 2, 'the meshes after the resize')
  expect.truthy(mesh.released, 'resizing releases the previous mesh')
  local replacement = env.meshes[2]
  expect.truthy(replacement.vertices[#replacement.vertices][1] ~= before, 'resizing replaces the geometry')
  curved:destroy(env.owner)
  expect.truthy(replacement.released, 'the retained mesh is released with the panel')
  for _, curve in { -1, 0 / 0, 'round' } do
    expect.raises(function()
      env.panels:fromWindow(env.owner, window(env, 4), { height = 1, curve = curve })
    end, nil, 'a curve of ' .. tostring(curve))
  end
  env.session:close()
end)

return test
