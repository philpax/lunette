-- One panel over a window or a monitor: its geometry, visibility, layer claim, and drawing. A panel reaches
-- its activation through its host rather than a module-global registry.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local surface = require '@lunette-contracts/surface'
local layer = require '@lunette-plugins/panels/layer'
local shape = require '@lunette-plugins/panels/shape'
local drawing = require '@lunette-plugins/panels/draw'

local panel = {}

export type Owner = contracts.Owner
export type Panel = contracts.Panel
export type Options = contracts.Options

-- The shape hooks, as around hooks over the flat quad or the arc of a positive curve.
export type RaycastBase = (Panel, vector, vector, boolean?) -> (number?, number?, number?)
export type Raycast = (Panel, vector, vector, boolean?, RaycastBase) -> (number?, number?, number?)
export type DrawBase = (Panel, Pass) -> ()
export type Draw = (Panel, Pass, DrawBase) -> ()
export type LayerBase = (Panel, Layer) -> ()
export type ApplyLayer = (Panel, Layer, LayerBase) -> ()
export type Shape = {
  read raycast: Raycast,
  read draw: Draw,
  read applyLayer: ApplyLayer,
}

-- The resolved options of the activation that made a panel.
export type Settings = {
  read style: contracts.Style,
  read priority: number,
  read height: number,
  read aspect: number,
  read chrome: boolean,
  read shape: Shape,
}

-- What a panel needs from the activation that made it.
export type Host = {
  read active: () -> boolean,
  -- Raises unless the owner is still a live owner of this activation.
  read checkOwner: (Owner) -> (),
  -- Checks the owner and registers a resource with its lifetime.
  read acquire: (Owner, () -> () -> ()) -> plugin.Effect,
  read settings: Settings,
  -- The activation's opaque shader, or nil when none can be made.
  read opaqueShader: () -> Shader?,
  -- Called once a panel is dead and its claim released.
  read removed: (State) -> (),
}

-- One owner's visibility override.
type Override = {
  owner: Owner,
  hidden: boolean,
  effect: plugin.Effect?,
}

type MutablePanel = {
  pose: Mat4,
  width: number,
  height: number,
  priority: number,
  title: string?,
  chrome: boolean,
  curve: number,
  hidden: boolean,
  highlighted: boolean,
  read setHighlighted: (surface.Surface, boolean) -> (),
  granted: boolean,
  dead: boolean,
  claim: layer.Claim?,
  appliedWidth: number?,
  appliedHeight: number?,
  owner: Owner,
  host: Host,
  overrides: { Override },
  mesh: Mesh?,
  meshKey: string?,
  -- The owner's effect that holds this panel, once the acquisition returns.
  effect: plugin.Effect?,
  read setPose: (surface.Surface, Mat4) -> (),
  read setSize: (surface.Surface, number?, number?) -> (),
  read raycast: (surface.Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read sink: (surface.Surface) -> lunette.Sink?,
  read sourceSize: (Panel) -> (number?, number?),
  read update: (Panel) -> (),
  read draw: (Panel, Pass) -> (),
  read setHidden: (Panel, Owner, contracts.Visibility) -> plugin.Effect,
  read destroy: (Panel, Owner) -> boolean,
}
export type Source =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }
export type State = MutablePanel & Source

-- A curve is a finite number, zero or more.
local function checkCurve(curve: unknown, level: number): number
  if type(curve) ~= 'number' or curve ~= curve or curve < 0 or curve == math.huge then
    error('panels: a curve is a finite number, zero or more, not ' .. tostring(curve), level)
  end
  return curve :: number
end

-- Creates a panel's state without registering it or acquiring a claim.
function panel.new(host: Host, owner: Owner, source: Source, options: Options?): State
  if source.source == nil then
    error('panels: a panel is over a source, and nil is not one', 4)
  end
  local settings: Options = options or {}
  local curve = checkCurve(if settings.curve == nil then 0 else settings.curve, 4)
  local created: State
  local function raycastBase(_self: Panel, origin: vector, direction: vector, backFace: boolean?)
    return panel.raycast(created, origin, direction, backFace)
  end
  local function drawBase(_self: Panel, pass: Pass)
    drawing.content(created, pass, host.opaqueShader)
  end
  local exposed = {
    setHighlighted = function(_self: surface.Surface, value: boolean)
      if not created.dead then
        created.highlighted = value
      end
    end,
    setPose = function(_self: surface.Surface, pose: Mat4)
      created.pose:set(pose)
    end,
    setSize = function(_self: surface.Surface, width: number?, height: number?)
      panel.resize(created, width, height)
    end,
    raycast = function(
      _self: surface.Surface,
      origin: vector,
      direction: vector,
      backFace: boolean?
    ): (number?, number?, number?)
      if created.dead or created.hidden then
        return nil, nil, nil
      end
      return host.settings.shape.raycast(created, origin, direction, backFace, raycastBase)
    end,
    sink = function(_self: surface.Surface): lunette.Sink?
      if created.dead or created.source.dead then
        return nil
      end
      return created.source.sink
    end,
    sourceSize = function(_self: Panel): (number?, number?)
      return panel.sourceSize(created)
    end,
    update = function(_self: Panel)
      panel.update(created)
    end,
    draw = function(_self: Panel, pass: Pass)
      if created.dead or created.hidden or created.source.dead then
        return
      end
      if created.chrome then
        drawing.chrome(created, pass, host.settings.style)
      end
      if created.granted then
        return
      end
      host.settings.shape.draw(created, pass, drawBase)
    end,
    setHidden = function(_self: Panel, caller: Owner, visibility: contracts.Visibility): plugin.Effect
      if type(visibility) ~= 'table' or type(visibility.hidden) ~= 'boolean' then
        error('panels: setHidden takes { hidden = boolean }', 2)
      end
      for key, _ in visibility :: { [unknown]: unknown } do
        if key ~= 'hidden' then
          error('panels: setHidden: unknown field ' .. tostring(key) .. '; the field is hidden', 2)
        end
      end
      return panel.setHidden(created, caller, visibility.hidden)
    end,
    destroy = function(_self: Panel, caller: Owner): boolean
      if created.dead then
        return false
      end
      if caller ~= created.owner then
        error('panels: only the owner that created a panel destroys it', 2)
      end
      return panel.retire(created)
    end,
  }
  local metatable = { __index = exposed }
  local pose = settings.pose and lovr.math.newMat4(settings.pose) or lovr.math.newMat4()
  local priority = settings.priority or host.settings.priority
  local chrome = if settings.chrome == nil then host.settings.chrome else settings.chrome
  local noClaim: layer.Claim? = nil
  local noSize: number? = nil
  local noEffect: plugin.Effect? = nil
  local noMesh: Mesh? = nil
  local noKey: string? = nil
  local descriptor: Source = source
  if descriptor.kind == 'window' then
    local window: lunette.Window = descriptor.source
    local target: MutablePanel & { read kind: 'window', read source: lunette.Window } = setmetatable({
      kind = 'window',
      source = window,
      pose = pose,
      width = 0,
      height = 0,
      priority = priority,
      title = settings.title,
      chrome = chrome,
      curve = curve,
      hidden = false,
      highlighted = false,
      granted = false,
      dead = false,
      claim = noClaim,
      appliedWidth = noSize,
      appliedHeight = noSize,
      owner = owner,
      host = host,
      overrides = {},
      mesh = noMesh,
      meshKey = noKey,
      effect = noEffect,
    }, metatable)
    created = target
  else
    local monitor: lunette.Monitor = descriptor.source
    local target: MutablePanel & { read kind: 'monitor', read source: lunette.Monitor } = setmetatable({
      kind = 'monitor',
      source = monitor,
      pose = pose,
      width = 0,
      height = 0,
      priority = priority,
      title = settings.title,
      chrome = chrome,
      curve = curve,
      hidden = false,
      highlighted = false,
      granted = false,
      dead = false,
      claim = noClaim,
      appliedWidth = noSize,
      appliedHeight = noSize,
      owner = owner,
      host = host,
      overrides = {},
      mesh = noMesh,
      meshKey = noKey,
      effect = noEffect,
    }, metatable)
    created = target
  end

  if settings.width or settings.height then
    panel.resize(created, settings.width, settings.height)
  else
    panel.resize(created, nil, host.settings.height)
  end
  return created
end

-- Gives up a panel's layer claim, so the panel is drawn in the scene again,
-- or not at all while it is hidden.
local function releaseClaim(target: State): ()
  local claim = target.claim
  target.claim = nil
  target.granted = false
  target.appliedWidth, target.appliedHeight = nil, nil
  if claim and not claim.dead then
    claim:release()
  end
end

-- Marks a panel dead, releases its claim, mesh, and visibility overrides,
-- and tells the host. Answers false for a panel that was already dead.
function panel.release(target: State): boolean
  if target.dead then
    return false
  end
  target.dead = true
  local overrides = table.clone(target.overrides)
  table.clear(target.overrides)
  target.hidden = false
  local mesh = target.mesh
  target.mesh, target.meshKey = nil, nil
  releaseClaim(target)
  if mesh then
    mesh:release()
  end
  for _, override in ipairs(overrides) do
    local effect = override.effect
    override.effect = nil
    if effect then
      effect:dispose()
    end
  end
  target.host.removed(target)
  return true
end

-- Ends a panel and then disposes its owner's effect. The release runs here rather than as the effect's
-- inverse because an owner's authority is withheld while its inverse runs, and removal listeners, the
-- panel's owner among them, must hear the removal as live owners.
function panel.retire(target: State): boolean
  if target.dead then
    return false
  end
  local effect = target.effect
  target.effect = nil
  local ok, failure = pcall(panel.release, target)
  if effect then
    effect:dispose()
  end
  if not ok then
    error(failure, 0)
  end
  return true
end

-- The most recent live override decides; with none the panel is shown. Hiding releases the layer claim at
-- once so the compositor does not draw it for another frame.
local function settle(target: State): ()
  local top = target.overrides[#target.overrides]
  local hidden = if top then top.hidden else false
  if target.hidden == hidden then
    return
  end
  target.hidden = hidden
  if hidden then
    releaseClaim(target)
  end
end

function panel.setHidden(target: State, caller: Owner, hidden: boolean): plugin.Effect
  -- A moved override becomes the most recent.
  for index, override in ipairs(target.overrides) do
    local effect = override.effect
    if override.owner == caller and effect then
      target.host.checkOwner(caller)
      table.remove(target.overrides, index)
      override.hidden = hidden
      table.insert(target.overrides, override)
      settle(target)
      return effect
    end
  end
  local entry: Override = { owner = caller, hidden = hidden, effect = nil }
  local acquired = target.host.acquire(caller, function(): () -> ()
    if not target.dead then
      table.insert(target.overrides, entry)
      settle(target)
    end
    return function(): ()
      local index = table.find(target.overrides, entry)
      if index then
        table.remove(target.overrides, index)
        settle(target)
      end
    end
  end)
  if not target.dead then
    entry.effect = acquired
  end
  return acquired
end

function panel.sourceSize(target: State): (number?, number?)
  local source: lunette.Textured = target.source
  if source.dead then
    return nil, nil
  end
  return source.width, source.height
end

function panel.resize(target: State, width: number?, height: number?)
  local pixelWidth, pixelHeight = panel.sourceSize(target)
  local aspect = target.host.settings.aspect
  if pixelWidth and pixelHeight and pixelWidth > 0 and pixelHeight > 0 then
    aspect = pixelWidth / pixelHeight
  end

  if not width and not height then
    error 'panels: a size needs a width, a height, or both'
  end
  local w: number = width or (height or 0) * aspect
  local h: number = height or w / aspect
  if not (w > 0) or not (h > 0) then
    error('panels: a panel is at least as large as nothing, and ' .. w .. 'x' .. h .. ' is not', 3)
  end
  target.width, target.height = w, h
end

-- The default raycast: the flat quad, or the arc a positive curve gives.
function panel.raycast(
  target: State,
  origin: vector,
  direction: vector,
  backFace: boolean?
): (number?, number?, number?)
  if target.dead then
    return nil, nil, nil
  end
  local pixelWidth, pixelHeight = panel.sourceSize(target)
  if not pixelWidth or not pixelHeight then
    return nil, nil, nil
  end
  return shape.hit({
    pose = target.pose,
    width = target.width,
    height = target.height,
    pixelWidth = pixelWidth,
    pixelHeight = pixelHeight,
    backFace = backFace,
    curve = target.curve,
  }, origin, direction)
end

local function needsClaim(target: State, pixelWidth: number, pixelHeight: number): boolean
  if target.kind ~= 'window' then
    return false
  end
  local claim = target.claim
  if not claim or claim.dead then
    return true
  end
  local layerWidth: number? = claim.width
  local layerHeight: number? = claim.height
  return not (layerWidth and layerHeight and pixelWidth <= layerWidth and pixelHeight <= layerHeight)
end

-- Acquires or replaces a window panel's layer claim when its source needs one.
-- A hidden panel holds none.
function panel.claim(target: State)
  if target.dead or target.hidden or target.source.dead then
    return
  end
  local pixelWidth, pixelHeight = panel.sourceSize(target)
  if not pixelWidth or not pixelHeight or pixelWidth <= 0 or pixelHeight <= 0 then
    return
  end
  if needsClaim(target, pixelWidth, pixelHeight) then
    target.host.checkOwner(target.owner)
    layer.sync(target, pixelWidth, pixelHeight)
  end
end

-- The default layer placement: the panel's pose, size, and curve.
local function applyLayerBase(target: State): LayerBase
  return function(_self: Panel, held: Layer): ()
    held:setPosition(target.pose:getPosition())
    held:setOrientation(target.pose:getOrientation())
    held:setDimensions(target.width, target.height)
    held:setCurve(target.curve)
  end
end

function panel.update(target: State)
  if target.dead then
    return
  end
  if target.source.dead then
    panel.retire(target)
    return
  end
  if target.hidden then
    if target.claim then
      releaseClaim(target)
    end
    return
  end

  local pixelWidth, pixelHeight = panel.sourceSize(target)
  if not pixelWidth or not pixelHeight or pixelWidth <= 0 or pixelHeight <= 0 then
    return
  end
  if not target.host.active() then
    return
  end
  panel.claim(target)
  if target.kind == 'window' then
    local base = applyLayerBase(target)
    layer.drive(target, pixelWidth, pixelHeight, function(held: Layer): ()
      target.host.settings.shape.applyLayer(target, held, base)
    end)
  end
end

return panel
