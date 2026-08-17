-- Covers lua/mullion/panel/init.lua, apart from the ray-quad intersection,
-- which lua/spec/mullion/panel/raycast_spec.lua covers.
--
-- The fakes and the module under test come from `spec.mullion.panel.fixture`,
-- which states why `lunette` is faked and why both specs share one install.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local signal = require '@mullion/signal'
local fixture = require '@spec/mullion/panel/fixture'

local spec = suite.new 'mullion.panel'

local panel = fixture.panel
local newSource = fixture.newSource
local newPass = fixture.newPass
local poseAt = fixture.poseAt
local TOLERANCE = fixture.TOLERANCE

-- Starts a case with nothing left over, and answers with the claim log so that
-- a case reads the claims it caused.
local function fresh()
  fixture.reset()
  return fixture.claims
end

-- What `panel.opaqueShader` answers while a case is drawing with one available.
-- The spec run has no graphics module, so there is no real shader to build and
-- a case about the shader has to supply its own.
local OPAQUE_SHADER = 'the opaque shader'

-- Draws `created` with a shader available, and answers the pass it drew into.
--
-- The stub is put back whether or not the draw raised, so that a failure here
-- does not leave every later case drawing through it.
local function drawWithOpaqueShader(created)
  local pass = newPass()
  local previous = panel.opaqueShader
  panel.opaqueShader = function()
    return OPAQUE_SHADER
  end

  local ok, raised = pcall(created.draw, created, pass)
  panel.opaqueShader = previous
  if not ok then
    error(raised, 0)
  end
  return pass
end

spec('a panel takes its width from the source aspect', function()
  fresh()
  local created = panel.fromWindow(newSource(1600, 900), { height = 1 })

  expect.near(created.width, 16 / 9, TOLERANCE, 'width')
  expect.near(created.height, 1, TOLERANCE, 'height')
end)

spec('a panel takes its height from the source aspect', function()
  fresh()
  local created = panel.fromWindow(newSource(1600, 900), { width = 2 })

  expect.near(created.height, 2 / (16 / 9), TOLERANCE, 'height')
end)

spec('a panel with no size given takes the default height', function()
  fresh()
  local created = panel.fromWindow(newSource(1600, 900))

  expect.near(created.height, panel.DEFAULT_HEIGHT, TOLERANCE, 'height')
end)

spec('setSize announces the change', function()
  fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  local seen = {}

  signal.connect(created, signal.propertyName 'height', function(_, value)
    seen[#seen + 1] = value
  end)
  created:setSize(nil, 2)

  expect.equal(#seen, 1, 'announcements')
  expect.near(seen[1], 2, TOLERANCE, 'the announced height')
end)

spec('setPose announces the change and copies the matrix', function()
  fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  local announced = 0

  signal.connect(created, signal.propertyName 'pose', function()
    announced = announced + 1
  end)

  local pose = poseAt(1, 2, -3)
  created:setPose(pose)
  -- Moving the caller's own matrix afterwards must not move the panel: a panel
  -- that kept the reference would follow a temporary the caller reused.
  pose:translate(10, 10, 10)

  local x, y, z = created.pose:getPosition()
  expect.equal(announced, 1, 'announcements')
  expect.near(x, 1, TOLERANCE, 'x')
  expect.near(y, 2, TOLERANCE, 'y')
  expect.near(z, -3, TOLERANCE, 'z')
end)

spec('a panel raycasts against its own source size', function()
  fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  created:setPose(poseAt(0, 0, -2))

  local x, y = created:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1))

  expect.near(x, 400, TOLERANCE, 'x')
  expect.near(y, 300, TOLERANCE, 'y')
end)

spec('a panel over a dead source raycasts nothing', function()
  fresh()
  local source = newSource(800, 600)
  local created = panel.fromWindow(source, { height = 1 })
  created:setPose(poseAt(0, 0, -2))

  source.dead = true
  expect.equal(created:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1)), nil, 'the raycast')
end)

spec('a window panel claims a layer at the source size', function()
  local claims = fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1, priority = 42 })

  created:update()

  expect.equal(#claims, 1, 'claim count')
  expect.equal(claims[1].requestedWidth, 800, 'requested width')
  expect.equal(claims[1].requestedHeight, 600, 'requested height')
  expect.equal(claims[1].priority, 42, 'priority')
end)

spec('a granted claim whose source is smaller than its layer sets a viewport matching the source', function()
  local claims = fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  created:update()

  -- The ladder quantises upwards, so an 800x600 request is served by a
  -- 1024x1024 layer and the source sits in its corner. Without the viewport the
  -- runtime would composite the whole square, drawing the window squeezed into
  -- the top-left quarter of it with blank around the rest. Phase 3's blit
  -- clears that margin, which makes it blank rather than making it absent.
  local layer = claims[1]:grant(1024, 1024)
  created:update()

  expect.truthy(created.granted, 'granted')
  expect.equal(#layer.viewports, 1, 'viewport count')
  expect.equal(layer.viewports[1].x, 0, 'viewport x')
  expect.equal(layer.viewports[1].y, 0, 'viewport y')
  expect.equal(layer.viewports[1].width, 800, 'viewport width')
  expect.equal(layer.viewports[1].height, 600, 'viewport height')
end)

spec('a granted claim drives the layer pose and metre dimensions', function()
  local claims = fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  created:setPose(poseAt(1, 2, -3))
  created:update()

  local layer = claims[1]:grant(1024, 1024)
  created:update()

  expect.equal(#layer.positions, 1, 'position count')
  expect.near(layer.positions[1].x, 1, TOLERANCE, 'position x')
  expect.near(layer.positions[1].y, 2, TOLERANCE, 'position y')
  expect.near(layer.positions[1].z, -3, TOLERANCE, 'position z')
  expect.equal(layer.orientations, 1, 'orientation count')
  expect.near(layer.dimensions.height, 1, TOLERANCE, 'metre height')
end)

spec('a viewport is set once per grant, not once per frame', function()
  local claims = fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  created:update()

  local layer = claims[1]:grant(1024, 1024)
  created:update()
  created:update()
  created:update()

  expect.equal(#layer.viewports, 1, 'viewport count')
end)

spec('a source that resizes within its layer gets a fresh viewport', function()
  local claims = fresh()
  local source = newSource(800, 600)
  local created = panel.fromWindow(source, { height = 1 })
  created:update()

  local layer = claims[1]:grant(1024, 1024)
  created:update()

  source.width, source.height = 900, 700
  created:update()

  expect.equal(#claims, 1, 'claim count, since the layer still holds it')
  expect.equal(#layer.viewports, 2, 'viewport count')
  expect.equal(layer.viewports[2].width, 900, 'the second viewport width')
  expect.equal(layer.viewports[2].height, 700, 'the second viewport height')
end)

spec('a source that outgrows its layer is reclaimed at the larger size', function()
  local claims = fresh()
  local source = newSource(800, 600)
  local created = panel.fromWindow(source, { height = 1 })
  created:update()
  claims[1]:grant(1024, 1024)
  created:update()

  source.width, source.height = 1600, 1200
  created:update()

  expect.equal(#claims, 2, 'claim count')
  expect.truthy(claims[1].released, 'the first claim was released')
  expect.equal(claims[2].requestedWidth, 1600, 'the second claim width')
  expect.falsy(created.granted, 'granted, while the new claim holds nothing')
end)

spec('a revocation returns the panel to the quad path without losing it', function()
  local claims = fresh()
  local source = newSource(800, 600, { texture = { name = 'a texture' } })
  local created = panel.fromWindow(source, { height = 1, chrome = false })
  created:update()
  claims[1]:grant(1024, 1024)
  created:update()
  expect.truthy(created.granted, 'granted')

  claims[1]:revoke()
  created:update()

  expect.falsy(created.granted, 'granted after the revocation')
  expect.falsy(created.dead, 'dead after the revocation')

  local pass = newPass()
  created:draw(pass)
  expect.equal(pass.planes, 1, 'planes drawn on the quad path')
  expect.equal(pass.material, source.texture, 'the material')
end)

spec('a re-grant after a revocation sets the viewport again', function()
  local claims = fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  created:update()
  claims[1]:grant(1024, 1024)
  created:update()

  claims[1]:revoke()
  created:update()
  -- A revoked claim takes a layer again as soon as one frees, and it is not the
  -- same layer, so the viewport it was told about last time went with the old
  -- one.
  local layer = claims[1]:grant(1024, 1024)
  created:update()

  expect.equal(#layer.viewports, 1, 'viewport count on the new layer')
end)

spec('a panel on a layer does not also draw its source as a quad', function()
  local claims = fresh()
  local source = newSource(800, 600, { texture = { name = 'a texture' } })
  local created = panel.fromWindow(source, { height = 1, chrome = false })
  created:update()
  claims[1]:grant(1024, 1024)
  created:update()

  local pass = newPass()
  created:draw(pass)

  -- Drawing it again would put a resampled copy in front of the sharp one the
  -- runtime is compositing.
  expect.equal(pass.planes, 0, 'planes drawn')
end)

spec('chrome is drawn on both paths', function()
  local claims = fresh()
  local source = newSource(800, 600, { texture = { name = 'a texture' } })
  local created = panel.fromWindow(source, { height = 1 })
  created:update()
  claims[1]:grant(1024, 1024)
  created:update()

  local onLayer = newPass()
  created:draw(onLayer)
  expect.equal(onLayer.planes, 1, 'the border while on a layer')
  expect.equal(onLayer.texts, 1, 'the title while on a layer')

  claims[1]:revoke()
  created:update()
  local onQuad = newPass()
  created:draw(onQuad)
  expect.equal(onQuad.planes, 2, 'the border and the source on the quad path')
end)

spec('chrome can be switched off', function()
  fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1, chrome = false })

  local pass = newPass()
  created:draw(pass)

  expect.equal(pass.texts, 0, 'titles drawn')
end)

spec('a source with no texture yet draws no quad', function()
  fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1, chrome = false })

  local pass = newPass()
  created:draw(pass)

  expect.equal(pass.planes, 0, 'planes drawn')
end)

-- A source reporting `opaque` has a padding byte where alpha would be, and most
-- clients leave it at zero, so a panel that sampled it would draw the window
-- fully invisible. docs/rendering.md#alpha makes forcing it to one the
-- consumer's job, and the shader is how the quad path does it.
spec('an opaque source is drawn through the opaque shader, which is then cleared', function()
  fresh()
  local source = newSource(800, 600, { texture = 'a texture', opaque = true })
  local created = panel.fromWindow(source, { height = 1, chrome = false })

  local pass = drawWithOpaqueShader(created)

  expect.equal(#pass.shaders, 2, 'shader calls')
  expect.equal(pass.shaders[1], OPAQUE_SHADER, 'the shader set')
  expect.equal(pass.shaders[2], false, 'the shader cleared')
end)

-- Drawn with a shader available, so that a panel setting one for every source
-- rather than for an opaque one is caught. Without the stub this case passes on
-- a run with no graphics module whatever the panel does, because there would be
-- no shader to set either way.
spec('a source that is not opaque sets no shader', function()
  fresh()
  local source = newSource(800, 600, { texture = 'a texture' })
  local created = panel.fromWindow(source, { height = 1, chrome = false })

  local pass = drawWithOpaqueShader(created)

  expect.equal(#pass.shaders, 0, 'shader calls')
  expect.equal(pass.planes, 1, 'planes drawn')
end)

-- The spec run switches the graphics module off, so there is nothing to build a
-- shader from. A panel then draws without the correction rather than raising,
-- which is what keeps a session with no graphics module — this one — able to
-- call `draw` at all.
spec('the opaque shader is nothing when there is no graphics module', function()
  expect.falsy(lovr.graphics, 'the graphics module')
  expect.equal(panel.opaqueShader(), nil, 'the shader')
end)

spec('an opaque source with no shader available still draws its quad', function()
  fresh()
  local source = newSource(800, 600, { texture = 'a texture', opaque = true })
  local created = panel.fromWindow(source, { height = 1, chrome = false })

  local pass = newPass()
  created:draw(pass)

  expect.equal(#pass.shaders, 0, 'shader calls')
  expect.equal(pass.planes, 1, 'planes drawn')
end)

spec('a dead source destroys the panel and releases its claim', function()
  local claims = fresh()
  local source = newSource(800, 600)
  local created = panel.fromWindow(source, { height = 1 })
  created:update()
  claims[1]:grant(1024, 1024)

  source.dead = true
  created:update()

  expect.truthy(created.dead, 'dead')
  expect.truthy(claims[1].released, 'released')
  expect.equal(#panel.all(), 0, 'live panels')
end)

spec('a destroyed panel announces it and draws nothing', function()
  fresh()
  local source = newSource(800, 600, { texture = { name = 'a texture' } })
  local created = panel.fromWindow(source, { height = 1, chrome = false })
  local announced = 0

  signal.connect(created, 'destroyed', function()
    announced = announced + 1
  end)
  expect.truthy(created:destroy(), 'the first destroy')
  expect.falsy(created:destroy(), 'the second destroy')
  expect.equal(announced, 1, 'announcements')

  local pass = newPass()
  created:draw(pass)
  expect.equal(pass.planes, 0, 'planes drawn')
end)

spec('a monitor panel never claims a layer', function()
  local claims = fresh()
  local created = panel.fromMonitor(newSource(2560, 1440), { height = 1 })

  created:update()

  -- `lunette.claimLayer` takes `window` and nothing else, so a mirrored screen
  -- has no way to ask. Noted as a gap in the native API at the module head.
  expect.equal(#claims, 0, 'claim count')
  expect.falsy(created.granted, 'granted')
end)

spec('a monitor panel draws as a quad', function()
  fresh()
  local source = newSource(2560, 1440, { texture = { name = 'a captured frame' } })
  local created = panel.fromMonitor(source, { height = 1, chrome = false })

  created:update()
  local pass = newPass()
  created:draw(pass)

  expect.equal(pass.planes, 1, 'planes drawn')
end)

spec('a panel hands over its source sink', function()
  fresh()
  local source = newSource(800, 600)
  local created = panel.fromWindow(source, { height = 1 })

  expect.equal(created:sink(), source.sink, 'the sink')

  source.dead = true
  expect.equal(created:sink(), nil, 'the sink once the source has gone')
end)

spec('all lists live panels in creation order', function()
  fresh()
  local first = panel.fromWindow(newSource(800, 600), { height = 1 })
  local second = panel.fromWindow(newSource(800, 600), { height = 1 })

  local live = panel.all()
  expect.equal(#live, 2, 'live count')
  expect.equal(live[1], first, 'the first')
  expect.equal(live[2], second, 'the second')

  first:destroy()
  expect.equal(#panel.all(), 1, 'live count after a destroy')
end)

spec('panel.update drives every panel', function()
  local claims = fresh()
  panel.fromWindow(newSource(800, 600), { height = 1 })
  panel.fromWindow(newSource(1920, 1080), { height = 1 })

  panel.update()

  expect.equal(#claims, 2, 'claim count')
end)

spec('panel.update survives a panel destroying itself part way through', function()
  fresh()
  local first = newSource(800, 600)
  panel.fromWindow(first, { height = 1 })
  panel.fromWindow(newSource(800, 600), { height = 1 })

  first.dead = true
  panel.update()

  expect.equal(#panel.all(), 1, 'live panels')
end)

spec('teardown destroys every panel and releases every claim', function()
  local claims = fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })
  created:update()

  panel.teardown()

  expect.truthy(created.dead, 'dead')
  expect.truthy(claims[1].released, 'released')
  expect.equal(#panel.all(), 0, 'live panels')
end)

spec('rejects a nil source', function()
  expect.raises(function()
    panel.fromWindow(nil, { height = 1 })
  end, 'nil is not one', 'fromWindow')
end)

spec('rejects a size with neither dimension', function()
  fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })

  expect.raises(function()
    created:setSize(nil, nil)
  end, 'a width, a height, or both', 'setSize')
end)

spec('rejects a size that is not positive', function()
  fresh()
  local created = panel.fromWindow(newSource(800, 600), { height = 1 })

  expect.raises(function()
    created:setSize(0, 1)
  end, 'at least as large as nothing', 'setSize')
end)

spec('requiring twice returns the same module', function()
  expect.equal(require '@mullion/panel', panel, 'the module')
end)

return spec
