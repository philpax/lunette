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
-- handling `lunette.onLayerGranted`. That is one code path instead of two, and it
-- leaves `lunette.onLayerGranted` free for a configuration that wants it: the
-- callback namespace belongs to the configuration, and a library that claimed
-- it would be taking it.
--
-- A monitor panel never claims a layer. `lunette.claimLayer` takes `window`
-- and nothing else (docs/lua-api.md#layer-claims), so a mirrored screen has no
-- way to ask for one and draws as a quad. That is a gap in the native API
-- rather than a decision made here.
--
-- The ray-quad intersection lives in `mullion.panel.raycast` and is re-exported
-- here as `panel.rayQuadHit`, which is the name docs/stdlib.md gives it. It is
-- pure arithmetic over a matrix and this file is claims, sources, and draw
-- calls, so the two were split when this one outgrew the size threshold.

local lunette = require '@lunette'
local pointing = require '@mullion/interaction/types'
local layer = require '@mullion/panel/layer'
local raycast = require '@mullion/panel/raycast'
local signal = require '@mullion/signal'
local teardown = require '@mullion/teardown'

local panel = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first. The metatable is a table rather than a forward-declared local
-- because `create` reads it before the methods below are filled in.
local methods = {}
local metatable = { __index = methods }
local create, sourceSize, remove, opaqueShaderFor

-- What a panel is over. The two are not interchangeable: only a window has a
-- property store and only a window may claim a layer.
export type Kind = 'window' | 'monitor'

-- A pixel source: one of the two the runtime has, and not a shape either might
-- fit. The set is closed, so it is a union, and `kind` below is what tells a
-- panel's own apart. `lunette.Textured` is the same union under the name the
-- native API gives it.
export type Source = lunette.Textured
-- A panel: a pixel source bound to a pose and a size in metres, plus the
-- methods that move it, size it, update it, draw it, and destroy it. The
-- method signatures are listed so that the checker resolves `created:setSize`
-- and narrows `self` fields; the created tables reach them through the
-- metatable, so the type and the implementations must agree by hand.
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
  -- The four `mullion.interaction` declares take its receiver, which is what
  -- makes a panel answer the surface contract with the receiver still checked.
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

-- A panel, discriminated on `kind`: testing it is what narrows `source` to the
-- handle that kind has, which is how `mullion.panel.layer` comes to know that
-- the thing it claims a layer for is a window.
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

-- Every panel, in creation order. Rebuilt when this file runs, so a soft reload
-- starts with none.
local panels: { Panel } = {}

-- The shader `opaqueShader` builds on first use, and nothing before it: the
-- graphics module does not exist while a configuration is being loaded, and a
-- module body that reached for it would make requiring this file depend on when
-- it was required. Dropped when this file runs again, so a soft reload builds
-- one against the state that will draw with it.
local opaqueShader: Shader?

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

-- Where a ray meets a quad, in the quad's own pixels.
--
-- `mullion.panel.raycast` holds it, and this is the name it is documented
-- under. A caller wanting it without the rest of this module requires that one.
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
-- portal dialog in front of the user, and a library deciding to make it would
-- be deciding that on the configuration's behalf.
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
-- Matched on `source.id` rather than on the handle itself. `lunette.windows()`
-- mints a fresh handle on every call, so the handle a panel was made with and
-- the handle a later enumeration answers with are two tables describing one
-- window and are not equal to each other. The identifier is what is stable, and
-- it is stable across a soft reload too
-- (docs/lua-api.md#per-window-properties), which is what makes re-adoption
-- possible at all.
--
-- A linear scan rather than an index: a session has tens of panels rather than
-- thousands, and an index would be another thing every destroy had to keep in
-- step with.
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
    -- source alone does not say which it is.
    if not existing.dead and existing.source.id == identity then
      return existing
    end
  end
  return nil
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
function panel.opaqueShader(): Shader?
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

-- Moves the panel. `pose` is a `Mat4`, and is copied rather than kept: a caller
-- reusing a temporary would otherwise move every panel it placed.
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
-- A panel is not the only way to reach a sink and does not own it; this is here
-- so that a caller holding a panel does not have to remember which of `window`
-- and `monitor` it wrapped.
function methods.sink(self: Panel): lunette.Sink?
  if self.dead or self.source.dead then
    return nil
  end
  return self.source.sink
end

-- Brings the panel up to date for this frame: checks its source, keeps its
-- layer claim in step with the source's size, and drives the layer when it
-- holds one.
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

  -- The claim and what it was granted are `mullion.panel.layer`'s, and a
  -- monitor panel never holds one.
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
  -- buffers, and is false while the source has committed nothing.
  local texture = source:getTexture()
  if not texture then
    return
  end

  -- A client's buffer holds premultiplied alpha; LÖVR's default alpha mode
  -- would multiply by it a second time and darken a translucent window twice.
  pass:setBlendMode('alpha', 'premultiplied')

  -- Read each frame alongside the texture rather than cached: `opaque` is a
  -- property of the buffer and changes when the client renegotiates its format
  -- (docs/rendering.md#alpha).
  local shader = opaqueShaderFor(self)
  if shader then
    pass:setShader(shader)
  end

  pass:setMaterial(texture)
  -- The size rides in the transform. `luax_readmat4` consumes a whole `Mat4`
  -- and reads the argument after it as the draw style, so a plane placed by
  -- matrix takes its extent from that matrix's scale and not from two more
  -- arguments.
  local transform = lovr.math.newMat4():set(self.pose):scale(self.width, self.height, 1)
  pass:plane(transform, 'fill', 1, 1)
  pass:setMaterial(nil)
  if shader then
    pass:setShader()
  end
  pass:setBlendMode('alpha', 'alphamultiply')
end

-- A border and a title. Not a widget layer: docs/stdlib.md defers 2D widgets,
-- and docs/stdlib.md records the toolkit as possibly a separate library
-- entirely, so this stays within `Pass:plane` and `Pass:text`.
function methods.drawChrome(self: Panel, pass: Pass)
  local style = panel.STYLE
  local color = self.highlighted and style.borderHighlightColor or style.borderColor

  pass:setColor(color[1], color[2], color[3], color[4])
  -- Behind the panel by a hair, so the two do not fight for the same depth, and
  -- larger by the border's thickness on each side. The extent rides in the
  -- transform's scale, for the reason `draw` records.
  local borderTransform = lovr.math
    .newMat4()
    :set(self.pose)
    :translate(0, 0, -style.borderDepth)
    :scale(self.width + style.borderThickness * 2, self.height + style.borderThickness * 2, 1)
  pass:plane(borderTransform, 'fill', 1, 1)

  -- Spelt out rather than as an `and`/`or` chain, whose type includes the
  -- `false` from the kind test even though its value never does.
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
-- collected (docs/lua-api.md#layer-claims). A configuration that drops a panel
-- without destroying it holds a layer out of the pool for the session's life.
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
-- A monitor's capture has no padding byte to mistake for alpha, so only a window
-- answers one. Takes the panel rather than reading it inline, because the
-- `kind` test is what narrows `source` to the handle that kind has, and a
-- `self` the guards above have already refined has no discriminant left.
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

-- Takes a panel out of the list, so that a long session does not accumulate
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
