-- Panels: a pixel source bound to a pose and a size in metres.
--
-- docs/dev/stdlib.md's tier 1. A panel binds a window or a monitor to a place in
-- the world, renders on a composition layer or as an in-scene quad, turns a
-- ray hit into a pixel coordinate, and draws chrome around it.
--
-- It is not a privileged object. docs/dev/stdlib.md states that a panel is an
-- abstraction over the primitives and that windows and sinks are usable without
-- one, so everything here is limited to what a configuration could call:
-- `lunette.claimLayer`, the source's own fields, and LÖVR.
--
-- Both realisations are live from the start. docs/dev/rendering.md describes the
-- in-scene quad as the fallback. The fallback is not a degraded mode. A claim
-- is revoked whenever a higher-priority one arrives at capacity, so a panel
-- that draws nothing while it holds no claim would disappear.
--
-- Grants and revocations happen on frame boundaries and never mid-frame
-- (docs/dev/lua-api.md#layer-claims), so `update` reads `claim.granted` and does
-- not handle `lunette.onLayerGranted`. The handling stays on one code path.
-- `lunette.onLayerGranted` stays free for a configuration to use; the callback
-- namespace belongs to the configuration, and a library claim would occupy it.
--
-- A monitor panel never claims a layer. `lunette.claimLayer` takes `window`
-- and no other argument (docs/dev/lua-api.md#layer-claims), so a mirrored screen
-- has no way to request a layer and draws as a quad. The absence of a claim
-- path is a native API gap, not a decision of the module.
-- The ray-quad intersection is in `mullion.panel.raycast` and is re-exported
-- here as `panel.rayQuadHit`, the name docs/dev/stdlib.md uses. The intersection is
-- pure arithmetic over a matrix; the panel module holds claims, sources, and
-- draw calls. The split keeps each file within the size threshold.

local lunette = require '@lunette'
local pointing = require '@mullion/interaction/types'
local layer = require '@mullion/panel/layer'
local raycast = require '@mullion/panel/raycast'
local signal = require '@mullion/signal'
local teardown = require '@mullion/teardown'

local panel = {}

-- The metatable is a table, not a forward-declared local, because `create`
-- reads it while the methods below are not yet filled in.
local methods = {}
local metatable = { __index = methods }
local create, sourceSize, remove, opaqueShaderFor

-- What a panel is over. The two are not interchangeable: a window has a
-- property store and may claim a layer; a monitor has neither.
export type Kind = 'window' | 'monitor'

-- A pixel source is one of the two kinds the runtime has, not a shape that
-- either kind might fit. The set is closed, so it is a union. `kind`
-- distinguishes which member a panel is. `lunette.Textured` is the same union
-- under its native name.
export type Source = lunette.Textured
-- A panel: a pixel source bound to a pose and a size in metres, plus the
-- methods that move it, size it, update it, draw it, and destroy it. The
-- method signatures are listed so the checker resolves `created:setSize` and
-- narrows `self` fields; the created tables reach them through the metatable,
-- so the type and the implementations must agree by hand.
-- The half of a panel that does not depend on what it is over.
type PanelFields = {
  pose: Mat4,
  width: number,
  height: number,
  priority: number,
  title: string?,
  chrome: boolean,
  highlighted: boolean,
  granted: boolean,
  dead: boolean,
  claim: layer.Claim?,
  appliedWidth: number?,
  appliedHeight: number?,
  -- `mullion.interaction` declares take the receiver, so the surface contract
  -- is satisfied with the receiver still checked.
  setPose: (pointing.Surface, Mat4) -> (),
  setSize: (pointing.Surface, number?, number?) -> (),
  raycast: (pointing.Surface, vector, vector, boolean?) -> (number?, number?, number?),
  sink: (pointing.Surface) -> lunette.Sink?,
  -- A panel's own, which nothing else implements.
  sourceSize: (Panel) -> (number?, number?),
  update: (Panel) -> (),
  draw: (Panel, Pass) -> (),
  drawChrome: (Panel, Pass) -> (),
  destroy: (Panel) -> boolean,
}

-- A panel, discriminated on `kind`: testing `kind` narrows `source` to the
-- handle that kind has, so `mullion.panel.layer` can claim a layer for the
-- window.
export type WindowPanel = PanelFields & { kind: 'window', source: lunette.Window }
export type MonitorPanel = PanelFields & { kind: 'monitor', source: lunette.Monitor }
export type Panel = WindowPanel | MonitorPanel
-- The options `fromWindow` and `fromMonitor` take.
type PanelOptions = {
  pose: Mat4?,
  width: number?,
  height: number?,
  priority: number?,
  title: string?,
  chrome: boolean?,
}
-- A LÖVR `Pass`, passed to draw callbacks and used for all drawing.

-- Every panel, in creation order. The list is rebuilt on reload, so a soft
-- reload starts with none.
local panels: { Panel } = {}

-- The shader `opaqueShader` builds on first use. The graphics module does not
-- exist while a configuration loads, and a module body calling it would make
-- requiring the module depend on require order. A soft reload rebuilds the
-- shader against the state that draws with it.
local opaqueShader: Shader?

-- Everything a panel's appearance is tuned with, in one table.
--
-- Feel accounts for most of the work at this tier, so a tuning pass changes
-- one table, not a hunt through functions for a number.
panel.STYLE = {
  -- The border's width, in metres, and its offset behind the panel, so the two
  -- do not occupy the same depth.
  borderThickness = 0.008,
  borderDepth = 0.001,
  borderColor = { 0.14, 0.14, 0.17, 0.95 },
  -- The border's colour when the panel is highlighted.
  borderHighlightColor = { 0.35, 0.55, 0.95, 0.95 },
  -- The title's height in metres and its offset above the panel.
  titleHeight = 0.04,
  titleMargin = 0.02,
  titleColor = { 1, 1, 1, 1 },
}

-- The priority a panel claims a layer with when its options give none.
--
-- A single number, because ranking is the configuration's: docs/dev/lua-api.md
-- states that lunette assigns no priority itself. Focus, gaze, and distance
-- are cases of a configuration computing a different one.
panel.DEFAULT_PRIORITY = 10

-- The metre height a panel takes when its options give neither dimension.
panel.DEFAULT_HEIGHT = 0.8

-- The fragment stage a source whose buffer has no alpha channel is drawn with.
--
-- An X-variant fourcc such as XR24 has no Vulkan format of its own, so it is
-- imported as the alpha-carrying format with the same component order. The
-- client's padding byte arrives as alpha. Most renderers leave that byte at
-- zero, so sampling it draws the window fully invisible. `source.opaque`
-- indicates the byte carries no meaning. docs/dev/rendering.md#alpha directs a
-- consumer to force alpha to one, not sample it. This shader is that consumer.
panel.OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    return vec4((Color * getPixel(ColorTexture, UV)).rgb, Color.a);
  }
]]

-- The aspect a panel falls back to when its source reports no size. A fresh
-- handle reports no size until its source has appeared in a snapshot.
panel.DEFAULT_ASPECT = 16 / 9

-- Where a ray meets a quad, in the quad's own pixels.
--
-- `mullion.panel.raycast` holds it, and that module documents this name. A
-- caller wanting it without the rest of the module requires that one.
panel.rayQuadHit = raycast.hit

-- A panel over a window lunette hosts.
--
-- `options` takes `pose`, a `Mat4`; `width` and `height` in metres, either of
-- which implies the other from the source's aspect; `priority` for the layer
-- claim; `title`, defaulting to the window's own; and `chrome`, which is on
-- unless it is `false`.
function panel.fromWindow(window: lunette.Window, options: PanelOptions?): WindowPanel
  return create(window, 'window', options) :: WindowPanel
end

-- A panel over one of the user's own screens.
--
-- Mirroring is not started here. `monitor:mirror()` is a request that may put a
-- portal dialog in front of the user. Starting it here would decide that on the
-- configuration's behalf.
function panel.fromMonitor(monitor: lunette.Monitor, options: PanelOptions?): MonitorPanel
  return create(monitor, 'monitor', options) :: MonitorPanel
end

-- Every live panel, in creation order, as a fresh table.
function panel.all(): { Panel }
  local live: { Panel } = {}
  for _, existing in ipairs(panels) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  return live
end

-- The live panel over `source`, or nothing.
--
-- Matching uses `source.id`, not the handle itself. `lunette.windows()`
-- creates a fresh handle on every call, so a panel's handle and a later
-- enumeration's handle are two tables describing one window and do not compare
-- equal. The identifier is stable, and it is stable across a soft reload too
-- (docs/dev/lua-api.md#per-window-properties), which makes re-adoption possible.
--
-- A linear scan serves a session with tens of panels, not thousands. An index
-- would add bookkeeping that every destroy must maintain.
function panel.forSource(source): Panel?
  if source == nil then
    return nil
  end

  local identity = source.id
  if identity == nil then
    return nil
  end
  for _, existing in ipairs(panels) do
    -- A window's identifier is a number and a monitor's is a string, so two
    -- kinds cannot collide on one value; the kinds are not compared because a
    -- source alone does not state which it is.
    if not existing.dead and existing.source.id == identity then
      return existing
    end
  end
  return nil
end

-- Brings every live panel up to date. Called once per frame, from `lovr.update`.
function panel.update()
  -- Iterates over a copy: destroying a panel whose source is dead removes it
  -- from the list while the loop runs.
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
-- correction, and because a spec asserting the quad path must identify the
-- shader it inspects.
function panel.opaqueShader(): Shader?
  if opaqueShader then
    return opaqueShader
  end
  -- Returns nothing when the graphics module is switched off. The headless
  -- spec run does that. A panel then draws without the correction, and no
  -- pass exists to draw into.
  if not (lovr and lovr.graphics and lovr.graphics.newShader) then
    return nil
  end

  opaqueShader = lovr.graphics.newShader('unlit', panel.OPAQUE_FRAGMENT)
  return opaqueShader
end

-- Destroys every panel. Registered as the module's teardown hook, because a
-- soft reload that left the old state's claims held would keep layers out of
-- the pool with nothing left to draw them.
function panel.teardown()
  for _, existing in ipairs(panel.all()) do
    existing:destroy()
  end
  panels = {}
end

-- Moves the panel. `pose` is a `Mat4` and is copied; keeping the caller's
-- table would move every panel a caller placed with one.
function methods.setPose(self: Panel, pose)
  self.pose:set(pose)
  signal.emit(self, signal.propertyName 'pose', self.pose)
end

-- Resizes the panel, in metres. Passing one dimension takes the other from the
-- source's aspect.
function methods.setSize(self: Panel, width: number?, height: number?)
  local pixelWidth, pixelHeight = sourceSize(self.source)
  local aspect = panel.DEFAULT_ASPECT
  if pixelWidth and pixelHeight and pixelWidth > 0 and pixelHeight > 0 then
    aspect = pixelWidth / pixelHeight
  end

  if not width and not height then
    error('mullion.panel: a size needs a width, a height, or both', 2)
  end
  local w: number = width or (height or 0) * aspect
  local h: number = height or w / aspect
  if not (w > 0) or not (h > 0) then
    error('mullion.panel: a panel is at least as large as nothing, and ' .. w .. 'x' .. h .. ' is not', 2)
  end

  signal.setProperty(self, 'width', w)
  signal.setProperty(self, 'height', h)
end

-- The source's size in pixels, or nothing when the source has gone.
function methods.sourceSize(self: Panel): (number?, number?)
  return sourceSize(self.source)
end

-- Where a ray meets this panel, in the source's pixels, or nothing.
function methods.raycast(
  self: Panel,
  origin: vector,
  direction: vector,
  backFace: boolean?
): (number?, number?, number?)
  if self.dead then
    return nil, nil, nil
  end
  local pixelWidth, pixelHeight = sourceSize(self.source)
  if not pixelWidth or not pixelHeight then
    return nil, nil, nil
  end

  return raycast.hit({
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
-- A panel is one way to reach a sink and does not own the sink. The caller
-- needs no knowledge of which of `window` and `monitor` the panel wraps.
function methods.sink(self: Panel): lunette.Sink?
  if self.dead or self.source.dead then
    return nil
  end
  return self.source.sink
end

-- Brings the panel up to date for this frame: checks its source, aligns its
-- layer claim with the source's size, and updates the layer when it holds one.
function methods.update(self: Panel)
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
  if not pixelWidth or not pixelHeight or pixelWidth <= 0 or pixelHeight <= 0 then
    return
  end

  -- The claim and the grant state belong to `mullion.panel.layer`, and a
  -- monitor panel never holds a claim.
  layer.sync(self, pixelWidth, pixelHeight)
  layer.drive(self, pixelWidth, pixelHeight)
end

-- Draws the panel as an in-scene quad, and its chrome.
--
-- Does nothing when the panel is on a layer: the runtime is compositing the
-- source itself, and drawing it again would put a resampled copy in front of a
-- sharp one. The chrome is still drawn, because the layer carries the source
-- and nothing else.
function methods.draw(self: Panel, pass: Pass)
  -- Through a local: refining `self.source` here would fix it to the union it
  -- already is, and the `kind` test below would have nothing left to narrow.
  local source = self.source
  if self.dead or source.dead then
    return
  end

  if self.chrome then
    self:drawChrome(pass)
  end

  if self.granted then
    return
  end

  -- Never cached across frames: the texture rotates as the client cycles its
  -- buffers, and is nil while the source has committed nothing.
  local texture = source:getTexture()
  if not texture then
    return
  end

  -- A client's buffer holds premultiplied alpha; LÖVR's default alpha mode
  -- would multiply by it a second time and darken a translucent window twice.
  pass:setBlendMode('alpha', 'premultiplied')

  -- Read each frame alongside the texture, not cached: `opaque` is a property
  -- of the buffer and changes when the client renegotiates its format
  -- (docs/dev/rendering.md#alpha).
  local shader = opaqueShaderFor(self)
  if shader then
    pass:setShader(shader)
  end

  pass:setMaterial(texture)
  -- The size is carried by the transform. `luax_readmat4` consumes a whole
  -- `Mat4` and reads the argument after it as the draw style, so a plane placed
  -- by matrix takes its extent from that matrix's scale, leaving the two size
  -- arguments unused.
  local transform = lovr.math.newMat4():set(self.pose):scale(self.width, self.height, 1)
  pass:plane(transform, 'fill', 1, 1)
  pass:setMaterial(nil)
  if shader then
    pass:setShader()
  end
  pass:setBlendMode('alpha', 'alphamultiply')
end

-- A border and a title. Not a widget layer: docs/dev/stdlib.md defers 2D widgets,
-- and docs/dev/stdlib.md records the toolkit as possibly a separate library
-- entirely, so this stays within `Pass:plane` and `Pass:text`.
function methods.drawChrome(self: Panel, pass: Pass)
  local style = panel.STYLE
  local color = self.highlighted and style.borderHighlightColor or style.borderColor

  pass:setColor(color[1], color[2], color[3], color[4])
  -- Offset behind the panel by `borderDepth`, so the two do not occupy the same
  -- depth, and larger by the border's thickness on each side. The extent is
  -- carried by the transform's scale, for the reason `draw` records.
  local borderTransform = lovr.math
    .newMat4()
    :set(self.pose)
    :translate(0, 0, -style.borderDepth)
    :scale(self.width + style.borderThickness * 2, self.height + style.borderThickness * 2, 1)
  pass:plane(borderTransform, 'fill', 1, 1)

  -- Spelt out, not as an `and`/`or` chain, whose type includes the `false`
  -- from the kind test even though its value never does.
  local title: string? = self.title or (if self.kind == 'window' then self.source.title else self.source.name)
  if title then
    pass:setColor(style.titleColor[1], style.titleColor[2], style.titleColor[3], style.titleColor[4])
    local above = lovr.math
      .mat4(self.pose)
      :translate(0, self.height / 2 + style.titleMargin + style.titleHeight / 2, 0)
      :scale(vector.pack(style.titleHeight))
    pass:text(title, above, 0, 'center', 'middle')
  end

  pass:setColor(1, 1, 1, 1)
end

-- Withdraws the panel: releases its claim, drops its connections, and takes it
-- out of the list.
--
-- Releasing is explicit, because nothing releases a claim when its handle is
-- collected (docs/dev/lua-api.md#layer-claims). A configuration that drops a panel
-- without destroying it holds a layer out of the pool until the session ends.
function methods.destroy(self: Panel): boolean
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

-- The shader a window whose buffer carries no alpha is drawn with, or nothing.
--
-- A monitor's capture has no padding byte to mistake for alpha, so a window
-- alone returns one. The argument is the panel, so the `kind` test narrows
-- `source` to the window handle; a refined `self` has no discriminant left.
function opaqueShaderFor(target: Panel): Shader?
  if target.kind ~= 'window' then
    return nil
  end
  return if target.source.opaque then panel.opaqueShader() else nil
end

-- The shared body of `fromWindow` and `fromMonitor`.
function create(source: Source, kind: Kind, options: PanelOptions?): Panel
  if source == nil then
    error('mullion.panel: a panel is over a source, and nil is not one', 3)
  end
  options = options or ({} :: PanelOptions)

  local created: Panel = setmetatable({
    source = source,
    kind = kind,
    pose = options.pose and lovr.math.newMat4(options.pose) or lovr.math.newMat4(),
    width = 0,
    height = 0,
    priority = options.priority or panel.DEFAULT_PRIORITY,
    title = options.title,
    chrome = options.chrome ~= false,
    highlighted = false,
    granted = false,
    dead = false,
    claim = nil,
    appliedWidth = nil,
    appliedHeight = nil,
  }, metatable) :: any

  if options.width or options.height then
    created:setSize(options.width, options.height)
  else
    created:setSize(nil, panel.DEFAULT_HEIGHT)
  end

  panels[#panels + 1] = created
  return created
end

-- A source's pixel size, or nothing when it has gone.
function sourceSize(source: Source): (number?, number?)
  if source.dead then
    return nil, nil
  end
  return source.width, source.height
end

-- Takes a panel out of the list, so a long session does not accumulate
-- dead entries.
function remove(destroyed: Panel)
  for index = 1, #panels do
    if panels[index] == destroyed then
      table.remove(panels, index)
      return
    end
  end
end

teardown.register('mullion.panel', panel.teardown)

return panel
