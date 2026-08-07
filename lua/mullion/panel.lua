-- Panels: a pixel source bound to a pose and a size in metres.
--
-- docs/stdlib.md's tier 1. A panel binds a window or a monitor to a place in
-- the world, decides between a composition layer and an in-scene quad, turns a
-- ray hit into a pixel coordinate, and draws a little chrome around it.
--
-- It is not a privileged object. docs/stdlib.md:21 is explicit that a panel is
-- an abstraction over the primitives and that windows and sinks are usable
-- without one, so nothing here reaches for anything a configuration could not
-- call: `lunette.claimLayer`, the source's own fields, and LÖVR.
--
-- Both realisations are live from the start. docs/rendering.md treats the
-- in-scene quad as the fallback rather than as a degraded mode, and a claim is
-- revoked whenever a higher-priority one arrives at capacity, so a panel that
-- only drew when it held a layer would disappear.
--
-- Grants and revocations land on frame boundaries and never mid-frame
-- (docs/lua-api.md#layer-claims), so `update` reads `claim.granted` rather than
-- handling `lovr.lunlayergranted`. That is one code path instead of two, and it
-- leaves `lovr.lunlayergranted` free for a configuration that wants it: the
-- callback namespace belongs to the configuration, and a library that claimed
-- it would be taking it.
--
-- A monitor panel never claims a layer. `lunette.claimLayer` takes `window`
-- and nothing else (docs/lua-api.md#layer-claims), so a mirrored screen has no
-- way to ask for one and draws as a quad. That is a gap in the native API
-- rather than a decision made here.

local lunette = require 'lunette'
local signal = require 'mullion.signal'
local teardown = require 'mullion.teardown'

local panel = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first. The metatable is a table rather than a forward-declared local
-- because `create` reads it before the methods below are filled in.
local methods = {}
local metatable = { __index = methods }
local create, readVector, sourceSize, remove

-- Every panel, in creation order. Rebuilt when this file runs, so a soft reload
-- starts with none.
local panels = {}

-- The shader `opaqueShader` builds on first use, and nothing before it: the
-- graphics module does not exist while a configuration is being loaded, and a
-- module body that reached for it would make requiring this file depend on when
-- it was required. Dropped when this file runs again, so a soft reload builds
-- one against the state that will draw with it.
local opaqueShader = nil

-- Everything a panel's appearance is tuned by, in one table.
--
-- Feel accounts for most of the work at this tier (docs/stdlib.md:27), so a
-- tuning pass should be a diff to one table rather than a hunt through
-- functions for a number.
panel.STYLE = {
  -- The border's width, in metres, and how far behind the panel it sits so
  -- that the two do not fight for the same depth.
  borderThickness = 0.008,
  borderDepth = 0.001,
  borderColor = { 0.14, 0.14, 0.17, 0.95 },
  -- The highlight a hovered panel's border takes. Interaction is Task 6's, and
  -- this is the colour it will reach for.
  borderHighlightColor = { 0.35, 0.55, 0.95, 0.95 },
  -- The title's height in metres, and how far above the panel it sits.
  titleHeight = 0.04,
  titleMargin = 0.02,
  titleColor = { 1, 1, 1, 1 },
}

-- What a panel asks for a layer with when its options name no priority.
--
-- A single number, because ranking is the configuration's: docs/lua-api.md says
-- lunette never invents a priority, and focus, gaze, and distance are all cases
-- of a configuration computing a different one.
panel.DEFAULT_PRIORITY = 10

-- The metre height a panel takes when its options give neither dimension.
panel.DEFAULT_HEIGHT = 0.8

-- The fragment stage a source whose buffer has no alpha channel is drawn with.
--
-- An X-variant fourcc such as XR24 has no Vulkan format of its own, so it is
-- imported as the alpha-carrying format with the same component order and the
-- client's padding byte arrives as alpha. Most renderers leave that byte at
-- zero, so sampling it draws the window fully invisible. `source.opaque` is what
-- says the byte means nothing, and docs/rendering.md#alpha says a consumer
-- forces alpha to one rather than sampling it. This is that consumer.
panel.OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    return vec4((Color * getPixel(ColorTexture, UV)).rgb, Color.a);
  }
]]

-- The aspect a panel falls back to when its source reports no size, which a
-- handle that has not yet seen its source in a snapshot does.
panel.DEFAULT_ASPECT = 16 / 9

-- A panel over a window lunette hosts.
--
-- `options` takes `pose`, a `Mat4`; `width` and `height` in metres, either of
-- which implies the other from the source's aspect; `priority` for the layer
-- claim; `title`, defaulting to the window's own; and `chrome`, which is on
-- unless it is `false`.
function panel.fromWindow(window, options)
  return create(window, 'window', options)
end

-- A panel over one of the user's own screens.
--
-- Mirroring is not started here. `monitor:mirror()` is a request that may put a
-- portal dialog in front of the user, and a library deciding to make it would
-- be deciding that on the configuration's behalf.
function panel.fromMonitor(monitor, options)
  return create(monitor, 'monitor', options)
end

-- Every live panel, in creation order, as a fresh table.
function panel.all()
  local live = {}
  for _, existing in ipairs(panels) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  return live
end

-- Brings every live panel up to date. Called once per frame, from `lovr.update`.
function panel.update()
  -- Over a copy: a panel whose source has died removes itself from the list
  -- while this runs.
  for _, existing in ipairs(panel.all()) do
    existing:update()
  end
end

-- Draws every panel that is not on a layer.
function panel.draw(pass)
  for _, existing in ipairs(panel.all()) do
    existing:draw(pass)
  end
end

-- The shader an opaque source is drawn with, or nothing when there is no
-- graphics module to build one from.
--
-- Public because a configuration drawing a source itself needs the same
-- correction, and because a spec asserting the quad path has to know which
-- shader it is looking at.
function panel.opaqueShader()
  if opaqueShader then
    return opaqueShader
  end
  -- Nothing when the graphics module is switched off, which is what the
  -- headless spec run does. A panel then draws without the correction, which is
  -- the same as drawing nothing at all in a session that has no pass to draw
  -- into.
  if not (lovr and lovr.graphics and lovr.graphics.newShader) then
    return nil
  end

  opaqueShader = lovr.graphics.newShader('unlit', panel.OPAQUE_FRAGMENT)
  return opaqueShader
end

-- Destroys every panel. Registered as this module's teardown hook, because a
-- soft reload that left the old state's claims held would keep layers out of
-- the pool with nothing left to draw them.
function panel.teardown()
  for _, existing in ipairs(panel.all()) do
    existing:destroy()
  end
  panels = {}
end

-- Where a ray meets a quad, in the quad's own pixels.
--
-- Returns the pixel coordinate and the distance along the ray, or nothing. The
-- pixel origin is the quad's top-left corner, because that is where a surface's
-- pixels start and what `sink:pointer` takes.
--
-- LÖVR has no ray-plane intersection to call: `Mat4` has no intersection
-- method, and the only raycasts in it are physics-world ones needing a
-- collider, which a panel has not got. So the maths is here, which
-- docs/input.md:22 says is where it belongs.
--
-- `quad` carries `pose`, a `Mat4`; `width` and `height` in metres;
-- `pixelWidth` and `pixelHeight`; and `backFace`, which allows a hit from
-- behind and is off by default. `origin` and `direction` are `Vec3`s or arrays
-- of three numbers. The direction need not be normalised, but the distance is
-- then in units of it rather than in metres.
function panel.rayQuadHit(quad, origin, direction)
  if quad.width <= 0 or quad.height <= 0 or quad.pixelWidth <= 0 or quad.pixelHeight <= 0 then
    return nil
  end

  local originX, originY, originZ = readVector(origin, 'the ray origin')
  local directionX, directionY, directionZ = readVector(direction, 'the ray direction')

  -- Into the quad's own space, where the quad is the rectangle at z = 0. The
  -- pose is copied first: `invert` writes in place, and inverting the panel's
  -- own pose would destroy it.
  local inverse = lovr.math.mat4(quad.pose):invert()
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  -- With w = 0, so the translation does not apply: this is a direction.
  local localDirectionX, localDirectionY, localDirectionZ =
    inverse:mul(directionX, directionY, directionZ, 0)

  -- A ray parallel to the plane meets it nowhere, and one travelling away from
  -- the viewer's side meets the back. A quad faces +z, as `Pass:plane` draws
  -- one, so a ray approaching the front travels towards -z.
  if localDirectionZ == 0 then
    return nil
  end
  if localDirectionZ > 0 and not quad.backFace then
    return nil
  end

  local distance = -localOriginZ / localDirectionZ
  -- Behind the ray's origin rather than in front of it. Zero is excluded too: a
  -- ray starting exactly on the plane is pointing along it as far as a panel is
  -- concerned.
  if not (distance > 0) then
    return nil
  end

  local hitX = localOriginX + distance * localDirectionX
  local hitY = localOriginY + distance * localDirectionY

  local halfWidth, halfHeight = quad.width / 2, quad.height / 2
  if hitX < -halfWidth or hitX > halfWidth or hitY < -halfHeight or hitY > halfHeight then
    return nil
  end

  -- Metres to pixels. The vertical axis flips: the quad's +y is up and a
  -- surface's +y is down.
  local pixelX = (hitX + halfWidth) / quad.width * quad.pixelWidth
  local pixelY = (halfHeight - hitY) / quad.height * quad.pixelHeight
  return pixelX, pixelY, distance
end

-- Moves the panel. `pose` is a `Mat4`, and is copied rather than kept: a caller
-- reusing a temporary would otherwise move every panel it placed.
function methods:setPose(pose)
  self.pose:set(pose)
  signal.emit(self, signal.propertyName 'pose', self.pose)
end

-- Resizes the panel, in metres. Passing one dimension takes the other from the
-- source's aspect.
function methods:setSize(width, height)
  local pixelWidth, pixelHeight = sourceSize(self.source)
  local aspect = panel.DEFAULT_ASPECT
  if pixelWidth and pixelHeight and pixelWidth > 0 and pixelHeight > 0 then
    aspect = pixelWidth / pixelHeight
  end

  if not width and not height then
    error('mullion.panel: a size needs a width, a height, or both', 2)
  end
  width = width or height * aspect
  height = height or width / aspect
  if not (width > 0) or not (height > 0) then
    error('mullion.panel: a panel is at least as large as nothing, and ' .. width .. 'x' .. height .. ' is not', 2)
  end

  signal.setProperty(self, 'width', width)
  signal.setProperty(self, 'height', height)
end

-- The source's size in pixels, or nothing when the source has gone.
function methods:sourceSize()
  return sourceSize(self.source)
end

-- Where a ray meets this panel, in the source's pixels, or nothing.
function methods:raycast(origin, direction, backFace)
  if self.dead then
    return nil
  end
  local pixelWidth, pixelHeight = sourceSize(self.source)
  if not pixelWidth then
    return nil
  end

  return panel.rayQuadHit({
    pose = self.pose,
    width = self.width,
    height = self.height,
    pixelWidth = pixelWidth,
    pixelHeight = pixelHeight,
    backFace = backFace,
  }, origin, direction)
end

-- The sink this panel's input goes to, or nothing when the source has gone.
--
-- A panel is not the only way to reach a sink and does not own it; this is here
-- so that a caller holding a panel does not have to remember which of `window`
-- and `monitor` it wrapped.
function methods:sink()
  if self.dead or self.source.dead then
    return nil
  end
  return self.source.sink
end

-- Brings the panel up to date for this frame: checks its source, keeps its
-- layer claim in step with the source's size, and drives the layer when it
-- holds one.
function methods:update()
  if self.dead then
    return
  end
  -- CONTRIBUTING.md: never assume a handle survives a frame. A client can exit
  -- between one frame and the next, and a panel over a window that has gone has
  -- nothing left to show.
  if self.source.dead then
    self:destroy()
    return
  end

  local pixelWidth, pixelHeight = sourceSize(self.source)
  if not pixelWidth or pixelWidth <= 0 or pixelHeight <= 0 then
    return
  end

  self:syncClaim(pixelWidth, pixelHeight)

  if not self.claim then
    return
  end

  local granted = self.claim.granted and true or false
  local resized = self.appliedWidth ~= pixelWidth or self.appliedHeight ~= pixelHeight

  if not granted then
    self.appliedWidth, self.appliedHeight = nil, nil
    signal.setProperty(self, 'granted', false)
    return
  end

  -- Never cached across frames: `claim.layer` names something that goes away on
  -- revoke, and re-acquiring it is cheap.
  local layer = self.claim.layer
  if not layer then
    return
  end

  -- On every grant and on every resize, which is what this phase owes Phase 3.
  -- The size ladder quantises upwards, so the layer is usually larger than the
  -- source and the blit lands at the layer's origin; the viewport is what
  -- excludes the margin. The blit clears that margin, but blank is not the same
  -- as absent — an 800x600 window in a 1024x1024 layer would otherwise be drawn
  -- squeezed into the top-left corner of a square.
  if resized or not self.granted then
    layer:setViewport(0, 0, pixelWidth, pixelHeight)
    self.appliedWidth, self.appliedHeight = pixelWidth, pixelHeight
  end

  layer:setPosition(self.pose:getPosition())
  -- As an angle and an axis, which is what `Mat4:getOrientation` hands back and
  -- what `luax_readquat` takes from four numbers. `lovr.math.quat` does not
  -- construct from a `Mat4`.
  layer:setOrientation(self.pose:getOrientation())
  layer:setDimensions(self.width, self.height)

  signal.setProperty(self, 'granted', true)
end

-- Draws the panel as an in-scene quad, and its chrome.
--
-- Does nothing when the panel is on a layer: the runtime is compositing the
-- source itself, and drawing it again would put a resampled copy in front of a
-- sharp one. The chrome is still drawn, because the layer carries the source
-- and nothing else.
function methods:draw(pass)
  if self.dead or self.source.dead then
    return
  end

  if self.chrome then
    self:drawChrome(pass)
  end

  if self.granted then
    return
  end

  -- Never cached across frames: the texture rotates as the client cycles its
  -- buffers, and is false while the source has committed nothing.
  local texture = self.source:getTexture()
  if not texture then
    return
  end

  -- A client's buffer holds premultiplied alpha; LÖVR's default alpha mode
  -- would multiply by it a second time and darken a translucent window twice.
  pass:setBlendMode('alpha', 'premultiplied')

  -- Read each frame alongside the texture rather than cached: `opaque` is a
  -- property of the buffer and changes when the client renegotiates its format
  -- (docs/rendering.md#alpha).
  local shader = self.source.opaque and panel.opaqueShader() or nil
  if shader then
    pass:setShader(shader)
  end

  pass:setMaterial(texture)
  -- The size rides in the transform. `luax_readmat4` consumes a whole `Mat4`
  -- and reads the argument after it as the draw style, so a plane placed by
  -- matrix takes its extent from that matrix's scale and not from two more
  -- arguments.
  pass:plane(lovr.math.mat4(self.pose):scale(self.width, self.height, 1))
  pass:setMaterial()
  if shader then
    pass:setShader()
  end
  pass:setBlendMode('alpha', 'alphamultiply')
end

-- A border and a title. Not a widget layer: docs/stdlib.md defers 2D widgets,
-- and docs/decisions.md records the toolkit as possibly a separate library
-- entirely, so this stays within `Pass:plane` and `Pass:text`.
function methods:drawChrome(pass)
  local style = panel.STYLE
  local color = self.highlighted and style.borderHighlightColor or style.borderColor

  pass:setColor(color[1], color[2], color[3], color[4])
  -- Behind the panel by a hair, so the two do not fight for the same depth, and
  -- larger by the border's thickness on each side. The extent rides in the
  -- transform's scale, for the reason `draw` records.
  pass:plane(lovr.math.mat4(self.pose):translate(0, 0, -style.borderDepth):scale(
    self.width + style.borderThickness * 2,
    self.height + style.borderThickness * 2,
    1
  ))

  local title = self.title or (self.kind == 'window' and self.source.title) or self.source.name
  if title then
    pass:setColor(style.titleColor[1], style.titleColor[2], style.titleColor[3], style.titleColor[4])
    local above = lovr.math
      .mat4(self.pose)
      :translate(0, self.height / 2 + style.titleMargin + style.titleHeight / 2, 0)
      :scale(style.titleHeight)
    pass:text(title, above, 0, 'center', 'middle')
  end

  pass:setColor(1, 1, 1, 1)
end

-- Withdraws the panel: releases its claim, drops its connections, and takes it
-- out of the list.
--
-- Releasing is explicit, because nothing releases a claim when its handle is
-- collected (docs/lua-api.md#layer-claims). A configuration that drops a panel
-- without destroying it holds a layer out of the pool for the session's life.
function methods:destroy()
  if self.dead then
    return false
  end

  self.dead = true
  if self.claim then
    self.claim:release()
    self.claim = nil
  end
  remove(self)
  signal.emit(self, 'destroyed')
  signal.disconnectAll(self)
  return true
end

-- Keeps the layer claim in step with the source's pixel size.
--
-- A window whose client resized past the layer it was granted needs a claim on
-- a larger rung, and the pool has no way to grow one underneath it: a claim
-- names a key, and the key carries the size. So the claim is released and
-- remade, which costs a frame or two on the quad path.
function methods:syncClaim(pixelWidth, pixelHeight)
  -- `lunette.claimLayer` takes a window and nothing else, so a monitor panel
  -- has no claim to keep in step. Noted at the module head as a gap in the
  -- native API rather than a choice made here.
  if self.kind ~= 'window' then
    return
  end

  if self.claim then
    local layerWidth, layerHeight = self.claim.width, self.claim.height
    -- A layer smaller than the source would crop it, and the ladder only
    -- quantises upwards, so this is the resized-past-its-rung case.
    if layerWidth and layerHeight and (pixelWidth <= layerWidth and pixelHeight <= layerHeight) then
      return
    end
    self.claim:release()
    self.claim = nil
    signal.setProperty(self, 'granted', false)
    self.appliedWidth, self.appliedHeight = nil, nil
  end

  self.claim = lunette.claimLayer {
    window = self.source,
    width = pixelWidth,
    height = pixelHeight,
    priority = self.priority,
  }
end

-- The shared body of `fromWindow` and `fromMonitor`.
function create(source, kind, options)
  if source == nil then
    error('mullion.panel: a panel is over a source, and nil is not one', 3)
  end
  options = options or {}

  local created = setmetatable({
    source = source,
    kind = kind,
    pose = lovr.math.newMat4(options.pose),
    width = 0,
    height = 0,
    priority = options.priority or panel.DEFAULT_PRIORITY,
    title = options.title,
    chrome = options.chrome ~= false,
    highlighted = false,
    granted = false,
    dead = false,
    claim = nil,
  }, metatable)

  if options.width or options.height then
    created:setSize(options.width, options.height)
  else
    created:setSize(nil, panel.DEFAULT_HEIGHT)
  end

  panels[#panels + 1] = created
  return created
end

-- A source's pixel size, or nothing when it has gone.
function sourceSize(source)
  if source.dead then
    return nil
  end
  return source.width, source.height
end

-- Three numbers out of a `Vec3` or an array of three.
--
-- Both, because `lovr.headset.getPosition` is wrapped in a `Vec3` and a
-- configuration that computed a ray itself is as likely to have three numbers
-- in a table. Anything else is a defect in the caller rather than a value to
-- guess at.
function readVector(value, name)
  local kind = type(value)
  if kind == 'userdata' or kind == 'cdata' then
    return value:unpack()
  end
  if kind == 'table' then
    if value.unpack then
      return value:unpack()
    end
    if type(value[1]) == 'number' and type(value[2]) == 'number' and type(value[3]) == 'number' then
      return value[1], value[2], value[3]
    end
  end
  error('mullion.panel: ' .. name .. ' is a Vec3 or three numbers, not a ' .. kind, 3)
end

-- Takes a panel out of the list, so that a long session does not accumulate
-- dead entries.
function remove(destroyed)
  for index = 1, #panels do
    if panels[index] == destroyed then
      table.remove(panels, index)
      return
    end
  end
end

teardown.register('mullion.panel', panel.teardown)

return panel
