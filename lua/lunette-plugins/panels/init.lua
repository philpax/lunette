-- A neutral panels provider.
--
-- Each activation owns one independent registry. Panel acquisition is tied to the
-- caller's owner, while queries and cleanup remain usable without an owner. No
-- module-global teardown or signal registry is used: the plugin context owns all
-- provider resources through effects.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local surface = require '@lunette-contracts/surface'
local vocabulary = require '@lunette-contracts/vocabulary'
local layer = require '@lunette-plugins/panels/layer'
local raycast = require '@lunette-plugins/panels/raycast'
local events = require '@lunette-plugins/panels/events'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Options = contracts.Options
export type Panel = contracts.Panel
export type WindowPanel = contracts.WindowPanel
export type MonitorPanel = contracts.MonitorPanel

local getOpaqueShader

type MutablePanel = {
  pose: Mat4,
  width: number,
  height: number,
  priority: number,
  title: string?,
  chrome: boolean,
  highlighted: boolean,
  read setHighlighted: (surface.Surface, boolean) -> (),
  granted: boolean,
  dead: boolean,
  claim: layer.Claim?,
  appliedWidth: number?,
  appliedHeight: number?,
  owner: Owner,
  service: Service,
  read setPose: (surface.Surface, Mat4) -> (),
  read setSize: (surface.Surface, number?, number?) -> (),
  read raycast: (surface.Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read sink: (surface.Surface) -> lunette.Sink?,
  read sourceSize: (Panel) -> (number?, number?),
  read update: (Panel) -> (),
  read draw: (Panel, Pass) -> (),
  read drawChrome: (Panel, Pass) -> (),
  destroy: (Panel) -> boolean,
}
type PanelSource =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }
type PanelState = MutablePanel & PanelSource

local methods: {
  setPose: (PanelState, Mat4) -> (),
  setSize: (PanelState, number?, number?) -> (),
  raycast: (PanelState, vector, vector, boolean?) -> (number?, number?, number?),
  sink: (PanelState) -> lunette.Sink?,
  sourceSize: (PanelState) -> (number?, number?),
  update: (PanelState) -> (),
  draw: (PanelState, Pass) -> (),
  drawChrome: (PanelState, Pass) -> (),
}

type ProviderState = {
  active: boolean,
  context: plugin.Context,
  service: Service,
  panels: { PanelState },
  opaqueShader: Shader?,
  shaderEffect: plugin.Effect?,
  events: events.Registry,
}

local states: { [Service]: ProviderState } = {}

-- Everything a panel's appearance is tuned with, in one table.
local STYLE = {
  borderThickness = 0.008,
  borderDepth = 0.001,
  borderColor = { 0.14, 0.14, 0.17, 0.95 },
  borderHighlightColor = { 0.35, 0.55, 0.95, 0.95 },
  titleHeight = 0.04,
  titleMargin = 0.02,
  titleColor = { 1, 1, 1, 1 },
}

local DEFAULT_PRIORITY = 10
local DEFAULT_HEIGHT = 0.8
local DEFAULT_ASPECT = 16 / 9
local function sourceSize(source: lunette.Textured): (number?, number?)
  if source.dead then
    return nil, nil
  end
  return source.width, source.height
end

local function remove(state: ProviderState, target: PanelState)
  for index = 1, #state.panels do
    if state.panels[index] == target then
      table.remove(state.panels, index)
      return
    end
  end
end

local function destroyRaw(target: PanelState): boolean
  if target.dead then
    return false
  end

  target.dead = true
  target.granted = false
  if target.claim then
    target.claim:release()
    target.claim = nil
  end

  local state = states[target.service]
  if state then
    remove(state, target)
  end
  events.releaseCleanup(target)
  return true
end

local function needsClaim(target: PanelState, pixelWidth: number, pixelHeight: number): boolean
  if target.kind ~= 'window' then
    return false
  end
  if not target.claim or target.claim.dead then
    return true
  end
  local layerWidth: number? = target.claim.width
  local layerHeight: number? = target.claim.height
  return not (layerWidth and layerHeight and pixelWidth <= layerWidth and pixelHeight <= layerHeight)
end

local function makePanel(state: ProviderState, owner: Owner, source: PanelSource, options: Options?): PanelState
  local actualSource = source.source
  if actualSource == nil then
    error('panels: a panel is over a source, and nil is not one', 3)
  end
  local settings: Options = options or {}
  local created: PanelState
  local exposed = {
    setHighlighted = function(_self: surface.Surface, value: boolean)
      if not created.dead then
        created.highlighted = value
      end
    end,
    setPose = function(_self: surface.Surface, pose: Mat4)
      methods.setPose(created, pose)
    end,
    setSize = function(_self: surface.Surface, width: number?, height: number?)
      methods.setSize(created, width, height)
    end,
    raycast = function(_self: surface.Surface, origin: vector, direction: vector, backFace: boolean?)
      return methods.raycast(created, origin, direction, backFace)
    end,
    sink = function(_self: surface.Surface): lunette.Sink?
      return methods.sink(created)
    end,
    sourceSize = function(_self: Panel): (number?, number?)
      return methods.sourceSize(created)
    end,
    update = function(_self: Panel)
      methods.update(created)
    end,
    draw = function(_self: Panel, pass: Pass)
      methods.draw(created, pass)
    end,
    drawChrome = function(_self: Panel, pass: Pass)
      methods.drawChrome(created, pass)
    end,
  }
  local function destroy(_self: Panel): boolean
    return destroyRaw(created)
  end
  local claim: layer.Claim? = nil
  local applied: number? = nil
  local metatable = { __index = exposed }
  local descriptor: PanelSource = source
  if descriptor.kind == 'window' then
    local window: lunette.Window = descriptor.source
    local target: MutablePanel & { read kind: 'window', read source: lunette.Window } = setmetatable({
      kind = 'window',
      source = window,
      pose = settings.pose and lovr.math.newMat4(settings.pose) or lovr.math.newMat4(),
      width = 0,
      height = 0,
      priority = settings.priority or DEFAULT_PRIORITY,
      title = settings.title,
      chrome = settings.chrome ~= false,
      highlighted = false,
      granted = false,
      dead = false,
      claim = claim,
      appliedWidth = applied,
      appliedHeight = applied,
      owner = owner,
      service = state.service,
      destroy = destroy,
    }, metatable)
    created = target
  else
    local monitor: lunette.Monitor = descriptor.source
    local target: MutablePanel & { read kind: 'monitor', read source: lunette.Monitor } = setmetatable({
      kind = 'monitor',
      source = monitor,
      pose = settings.pose and lovr.math.newMat4(settings.pose) or lovr.math.newMat4(),
      width = 0,
      height = 0,
      priority = settings.priority or DEFAULT_PRIORITY,
      title = settings.title,
      chrome = settings.chrome ~= false,
      highlighted = false,
      granted = false,
      dead = false,
      claim = claim,
      appliedWidth = applied,
      appliedHeight = applied,
      owner = owner,
      service = state.service,
      destroy = destroy,
    }, metatable)
    created = target
  end

  if settings.width or settings.height then
    created:setSize(settings.width, settings.height)
  else
    created:setSize(nil, DEFAULT_HEIGHT)
  end

  state.panels[#state.panels + 1] = created
  return created
end

local function createClaimIfLive(state: ProviderState, target: PanelState)
  if target.dead or target.source.dead then
    return
  end
  local pixelWidth, pixelHeight = sourceSize(target.source)
  if not pixelWidth or not pixelHeight or pixelWidth <= 0 or pixelHeight <= 0 then
    return
  end
  if needsClaim(target, pixelWidth, pixelHeight) then
    state.context:checkOwner(target.owner)
    layer.sync(target, pixelWidth, pixelHeight)
  end
end

local function create(state: ProviderState, owner: Owner, source: PanelSource, options: Options?): PanelState
  local created: PanelState?
  local cleanupEffect: plugin.Effect?
  local acquired = owner:effect(function()
    local target = makePanel(state, owner, source, options)
    created = target
    target.destroy = function(_self: Panel): boolean
      if target.dead then
        return false
      end
      local effect = cleanupEffect
      if effect then
        effect:dispose()
        return true
      end
      return destroyRaw(target)
    end
    -- The runtime cannot register an inverse until this acquisition returns.
    local ok, failure = pcall(function()
      createClaimIfLive(state, target)
    end)
    if not ok then
      destroyRaw(target)
      error(failure)
    end
    return function()
      cleanupEffect = nil
      destroyRaw(target)
    end
  end)
  local target = assert(created)
  if target.dead then
    acquired:dispose()
  else
    cleanupEffect = acquired
  end
  return target
end

methods = {
  setPose = function(target: PanelState, pose: Mat4)
    target.pose:set(pose)
  end,

  setSize = function(target: PanelState, width: number?, height: number?)
    local pixelWidth, pixelHeight = sourceSize(target.source)
    local aspect = DEFAULT_ASPECT
    if pixelWidth and pixelHeight and pixelWidth > 0 and pixelHeight > 0 then
      aspect = pixelWidth / pixelHeight
    end

    if not width and not height then
      error 'panels: a size needs a width, a height, or both'
    end
    local w: number = width or (height or 0) * aspect
    local h: number = height or w / aspect
    if not (w > 0) or not (h > 0) then
      error('panels: a panel is at least as large as nothing, and ' .. w .. 'x' .. h .. ' is not', 2)
    end
    target.width, target.height = w, h
  end,

  sourceSize = function(target: PanelState): (number?, number?)
    return sourceSize(target.source)
  end,

  raycast = function(
    target: PanelState,
    origin: vector,
    direction: vector,
    backFace: boolean?
  ): (number?, number?, number?)
    if target.dead then
      return nil, nil, nil
    end
    local pixelWidth, pixelHeight = sourceSize(target.source)
    if not pixelWidth or not pixelHeight then
      return nil, nil, nil
    end
    return raycast.hit({
      pose = target.pose,
      width = target.width,
      height = target.height,
      pixelWidth = pixelWidth,
      pixelHeight = pixelHeight,
      backFace = backFace,
    }, origin, direction)
  end,

  sink = function(target: PanelState): lunette.Sink?
    if target.dead or target.source.dead then
      return nil
    end
    return target.source.sink
  end,

  update = function(target: PanelState)
    if target.dead then
      return
    end
    if target.source.dead then
      target:destroy()
      return
    end

    local pixelWidth, pixelHeight = sourceSize(target.source)
    if not pixelWidth or not pixelHeight or pixelWidth <= 0 or pixelHeight <= 0 then
      return
    end

    local state = states[target.service]
    if not state or not state.active then
      return
    end
    createClaimIfLive(state, target)
    if target.kind == 'window' then
      layer.drive(target, pixelWidth, pixelHeight)
    end
  end,

  draw = function(target: PanelState, pass: Pass)
    local source = target.source
    if target.dead or source.dead then
      return
    end

    if target.chrome then
      target:drawChrome(pass)
    end
    if target.granted then
      return
    end

    local texture: Texture | false
    local shader: Shader?
    local state = states[target.service]
    local panelSource: PanelSource = target
    if panelSource.kind == 'window' then
      local window = panelSource.source
      texture = window:getTexture()
      if window.opaque and state then
        shader = getOpaqueShader(target.service)
      end
    else
      local monitor = panelSource.source
      texture = monitor:getTexture()
    end
    if not texture then
      return
    end

    pass:setBlendMode('alpha', 'premultiplied')
    if shader then
      pass:setShader(shader)
    end

    pass:setMaterial(texture)
    local transform = lovr.math.newMat4():set(target.pose):scale(target.width, target.height, 1)
    pass:plane(transform, 'fill', 1, 1)
    pass:setMaterial(nil)
    if shader then
      pass:setShader()
    end
    pass:setBlendMode('alpha', 'alphamultiply')
  end,

  drawChrome = function(target: PanelState, pass: Pass)
    local state = states[target.service]
    local style = state and target.service.STYLE or STYLE
    local color = target.highlighted and style.borderHighlightColor or style.borderColor

    pass:setColor(color[1], color[2], color[3], color[4])
    local borderTransform = lovr.math.newMat4():set(target.pose):translate(0, 0, -style.borderDepth):scale(
      target.width + style.borderThickness * 2,
      target.height + style.borderThickness * 2,
      1
    )
    pass:plane(borderTransform, 'fill', 1, 1)

    local title: string? = target.title
    if not title then
      title = if target.kind == 'window' then target.source.title else target.source.name
    end
    if title then
      pass:setColor(style.titleColor[1], style.titleColor[2], style.titleColor[3], style.titleColor[4])
      local above = lovr.math
        .mat4(target.pose)
        :translate(0, target.height / 2 + style.titleMargin + style.titleHeight / 2, 0)
        :scale(vector.pack(style.titleHeight))
      pass:text(title, above, 0, 'center', 'middle')
    end
    pass:setColor(1, 1, 1, 1)
  end,
}

local function livePanels(state: ProviderState): { Panel }
  local live: { Panel } = {}
  for _, target in ipairs(state.panels) do
    if not target.dead then
      live[#live + 1] = target
    end
  end
  return live
end

local function releaseShader(shader: Shader)
  shader:release()
end

function getOpaqueShader(service: Service): Shader?
  local state = states[service]
  if not state or not state.active or not state.context:active() then
    return nil
  end
  if state.opaqueShader then
    return state.opaqueShader
  end
  if not (lovr and lovr.graphics and lovr.graphics.newShader) then
    return nil
  end

  state.shaderEffect = state.context:effect(function()
    if not state.context:active() then
      return function() end
    end
    local shader = lovr.graphics.newShader('unlit', service.OPAQUE_FRAGMENT)
    state.opaqueShader = shader
    return function()
      releaseShader(shader)
      state.opaqueShader = nil
      state.shaderEffect = nil
    end
  end)
  return state.opaqueShader
end

local function getOwnedOpaqueShader(state: ProviderState, owner: Owner): Shader?
  state.context:checkOwner(owner)
  return getOpaqueShader(state.service)
end

local function destroyAll(state: ProviderState)
  local live = livePanels(state)
  for _, target in ipairs(live) do
    target:destroy()
  end
  state.panels = {}
end

local function init(context: plugin.Context): Service
  local service: Service
  -- The published service is revoked with this activation, so its methods
  -- need no liveness guard. Panels are not reached through the service after
  -- they are created, and they check the registry below themselves.
  local state: ProviderState
  local implementation = {
    STYLE = STYLE,
    DEFAULT_PRIORITY = DEFAULT_PRIORITY,
    DEFAULT_HEIGHT = DEFAULT_HEIGHT,
    DEFAULT_ASPECT = DEFAULT_ASPECT,
    OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    return vec4((Color * getPixel(ColorTexture, UV)).rgb, Color.a);
  }
]],
  }
  function implementation.rayQuadHit(_self: Service, quad: contracts.Quad, origin: vector, direction: vector)
    return raycast.hit(quad, origin, direction)
  end

  function implementation.fromWindow(
    _self: Service,
    owner: Owner,
    window: lunette.Window,
    options: Options?
  ): WindowPanel
    state.context:checkOwner(owner)
    local target = create(state, owner, { kind = 'window', source = window }, options)
    if target.kind ~= 'window' then
      error 'panels: window constructor returned a monitor panel'
    end
    return target
  end

  function implementation.fromMonitor(
    _self: Service,
    owner: Owner,
    monitor: lunette.Monitor,
    options: Options?
  ): MonitorPanel
    state.context:checkOwner(owner)
    local target = create(state, owner, { kind = 'monitor', source = monitor }, options)
    if target.kind ~= 'monitor' then
      error 'panels: monitor constructor returned a window panel'
    end
    return target
  end

  function implementation.all(_self: Service): { Panel }
    return livePanels(state)
  end

  function implementation.forSource(_self: Service, source: contracts.Source): Panel?
    if source == nil then
      return nil
    end
    local identity = source.id
    for _, target in ipairs(state.panels) do
      if not target.dead and target.source.id == identity then
        return target
      end
    end
    return nil
  end

  function implementation.update(_self: Service)
    for _, target in ipairs(livePanels(state)) do
      target:update()
    end
  end

  function implementation.draw(_self: Service, pass: Pass)
    for _, target in ipairs(livePanels(state)) do
      target:draw(pass)
    end
  end

  function implementation.opaqueShader(_self: Service, owner: Owner): Shader?
    return getOwnedOpaqueShader(state, owner)
  end

  function implementation.onDropped(
    _self: Service,
    owner: Owner,
    panel: contracts.Panel?,
    callback: contracts.DroppedCallback
  ): plugin.Effect
    return events.onDropped(state.events, state.context, owner, panel, callback)
  end

  function implementation.emitDropped(_self: Service, owner: Owner, panel: Panel, pointer: vocabulary.Pointer)
    events.emitDropped(state.events, state.context, owner, panel, pointer)
  end

  service = implementation
  local created: ProviderState = {
    active = true,
    context = context,
    service = service,
    panels = {},
    opaqueShader = nil,
    shaderEffect = nil,
    events = events.new(),
  }
  state = created
  states[service] = state
  context:effect(function()
    return function()
      state.active = false
      events.clear(state.events)
      destroyAll(state)
      states[service] = nil
    end
  end)
  return service
end

local capability = contracts.capability
local provided = { panels = capability }

return plugin.define(
  function(config: {}): {}
    return config
  end,
  {},
  provided,
  function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    publish:provide(capability, init(context))
  end
)
