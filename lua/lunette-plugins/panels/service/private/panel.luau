-- A panel reaches its activation through its host, which keeps provider state activation-scoped.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local layer = require './layer'
local shape = require './shape'
local drawing = require './draw'
local passState = require '@lunette-plugins/graphics/pass-state'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local appearance = require './appearance'
local vocabulary = require '@lunette-contracts/vocabulary'
local frame = require './frame'
local silhouette = require './silhouette'
local children = require './children'
local curved = require '@lunette-plugins/graphics/curved-surface'

local panel = {}

export type Owner = contracts.Owner
export type Panel = contracts.Panel
export type Options = contracts.Options

local config = require '../config'

export type Settings = config.Settings

export type Host = {
  read active: () -> boolean,
  -- Raises unless the owner is still a live owner of this activation.
  read checkOwner: (Owner) -> (),
  -- Checks the owner and registers a resource with its lifetime.
  read acquire: (Owner, () -> () -> ()) -> plugin.Effect,
  read settings: Settings,
  read paint: () -> appearance.Paint,
  -- The activation's colour conversion shader for opaque or premultiplied captured content.
  read contentShader: (boolean) -> Shader?,
  -- Called once a panel is dead and its claim released.
  read removed: (State) -> (),
  read lockChanged: (State) -> (),
  read curveChanged: (State) -> (),
  read transformLockChanged: (State) -> (),
  -- Whether the headset composites curved layers, cached once per update.
  read layerCurve: () -> boolean,
}

type Override = {
  owner: Owner,
  hidden: boolean,
  effect: plugin.Effect?,
}

type PanelData = {
  pose: Mat4,
  width: number,
  height: number,
  sizeAxis: 'width' | 'height' | 'fixed',
  sourceAspect: number,
  priority: number,
  title: string?,
  chrome: boolean,
  curve: number,
  curveExplicit: boolean,
  hidden: boolean,
  locked: boolean,
  lockedExplicit: boolean,
  transformLocked: boolean,
  transformLockedExplicit: boolean,
  highlighted: boolean,
  granted: boolean,
  dead: boolean,
  claim: layer.Claim?,
  appliedViewport: layer.Viewport?,
  owner: Owner,
  host: Host,
  overrides: { Override },
  mesh: Mesh?,
  meshKey: string?,
  meshCurve: number?,
  meshTransform: string?,
  meshCrop: string?,
  outline: drawing.Outline?,
  childMeshes: children.Cache?,
  contour: silhouette.Cache?,
  frame: frame.Record?,
  effect: plugin.Effect?,
}

type PanelMethods = {
  read attachFrame: (vocabulary.Surface, Owner, vocabulary.FrameStyle) -> vocabulary.FrameAttachment,
  read setHighlighted: (vocabulary.Surface, boolean) -> (),
  read setPose: (vocabulary.Surface, Mat4) -> (),
  read setSize: (vocabulary.Surface, number?, number?) -> (),
  read raycast: (vocabulary.Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read sink: (vocabulary.Surface) -> lunette.Sink?,
  read update: (Panel) -> (),
  read draw: (Panel, Pass) -> (),
  read setHidden: (Panel, Owner, boolean) -> plugin.Effect,
  read setLocked: (Panel, Owner, boolean) -> boolean,
  read setCurve: (Panel, number, boolean?) -> boolean,
  read setTransformLocked: (Panel, Owner, boolean) -> boolean,
  read close: (Panel, Owner) -> boolean,
  read destroy: (Panel, Owner) -> boolean,
}
export type Source =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }
export type State = PanelData & PanelMethods & Source

local function checkCurve(curve: unknown, level: number): number
  if type(curve) ~= 'number' or curve ~= curve or curve < 0 or curve == math.huge then
    error('panels: a curve is a finite number, zero or more, not ' .. tostring(curve), level)
  end
  return curve :: number
end

function panel.new(host: Host, owner: Owner, source: Source, options: Options?): State
  if source.source == nil then
    error('panels: a panel is over a source, and nil is not one', 4)
  end
  local settings: Options = options or {}
  if settings.locked ~= nil and type(settings.locked) ~= 'boolean' then
    error('panels: locked is a boolean, not a ' .. type(settings.locked), 4)
  end
  if settings.transformLocked ~= nil and type(settings.transformLocked) ~= 'boolean' then
    error('panels: transformLocked is a boolean, not a ' .. type(settings.transformLocked), 4)
  end
  local curve = checkCurve(if settings.curve == nil then 0 else settings.curve, 4)
  local created: State
  local exposed: PanelMethods = {
    attachFrame = function(
      _self: vocabulary.Surface,
      caller: Owner,
      style: vocabulary.FrameStyle
    ): vocabulary.FrameAttachment
      return frame.attach(created, caller, style)
    end,
    setHighlighted = function(_self: vocabulary.Surface, value: boolean)
      if not created.dead then
        created.highlighted = value
      end
    end,
    setPose = function(_self: vocabulary.Surface, pose: Mat4)
      created.pose:set(pose)
    end,
    setSize = function(_self: vocabulary.Surface, width: number?, height: number?)
      panel.resize(created, width, height)
    end,
    raycast = function(
      _self: vocabulary.Surface,
      origin: vector,
      direction: vector,
      backFace: boolean?
    ): (number?, number?, number?)
      if created.dead or created.hidden then
        return nil, nil, nil
      end
      return panel.raycast(created, origin, direction, backFace)
    end,
    sink = function(_self: vocabulary.Surface): lunette.Sink?
      if created.dead or created.source.dead or created.locked then
        return nil
      end
      return created.source.sink
    end,
    update = function(_self: Panel)
      panel.update(created)
    end,
    draw = function(_self: Panel, pass: Pass)
      if created.dead or created.hidden or created.source.dead then
        return
      end
      local paint = host.paint()
      local function current(): boolean
        return host.active() and not created.dead and not created.hidden and not created.source.dead
      end
      local function render(font: Font?): ()
        passState.withRestore(pass, function()
          pass:setShader()
          pass:setMaterial(nil)
          pass:setColor(1, 1, 1, 1)
          if created.granted then
            local previous = created.mesh
            created.mesh, created.meshKey = nil, nil
            if previous then
              previous:release()
            end
            if created.chrome then
              drawing.border(created, pass, paint.style)
            else
              drawing.clearOutline(created)
            end
          end
          if created.chrome and font and not (created.frame and created.frame.live) then
            pass:setFont(font)
            drawing.chrome(created, pass, paint.style, font)
          end
          if current() and host.paint() == paint and not created.granted then
            if created.chrome or frame.joined(created.frame) then
              drawing.border(created, pass, paint.style)
            else
              drawing.clearOutline(created)
            end
            drawing.content(created, pass, paint.style, host.contentShader)
          end
        end)
      end
      if created.chrome then
        render(paint.font)
      else
        render(nil)
      end
    end,
    setHidden = function(_self: Panel, caller: Owner, hidden: boolean): plugin.Effect
      if type(hidden) ~= 'boolean' then
        error('panels setHidden: hidden is a boolean, not a ' .. type(hidden), 2)
      end
      return panel.setHidden(created, caller, hidden)
    end,
    setLocked = function(_self: Panel, caller: Owner, locked: boolean): boolean
      if type(locked) ~= 'boolean' then
        error('panels setLocked: locked is a boolean, not a ' .. type(locked), 2)
      end
      host.checkOwner(caller)
      if created.dead or created.source.dead or created.locked == locked then
        return false
      end
      created.locked = locked
      host.lockChanged(created)
      return true
    end,
    setCurve = function(_self: Panel, curve: number, commit: boolean?): boolean
      local value = checkCurve(curve, 2)
      if created.dead then
        return false
      end
      local changed = created.curve ~= value
      -- A commit notifies even when the value is unchanged; a preview of the same value does nothing.
      if not changed and commit ~= true then
        return false
      end
      created.curve = value
      -- The next update re-decides whether the layer or the scene draws the curve.
      if created.claim then
        layer.release(created)
      end
      if commit == true then
        host.curveChanged(created)
      end
      return true
    end,
    setTransformLocked = function(_self: Panel, caller: Owner, locked: boolean): boolean
      if type(locked) ~= 'boolean' then
        error('panels setTransformLocked: transformLocked is a boolean, not a ' .. type(locked), 2)
      end
      host.checkOwner(caller)
      if created.dead or created.source.dead or created.transformLocked == locked then
        return false
      end
      created.transformLocked = locked
      host.transformLockChanged(created)
      return true
    end,
    close = function(_self: Panel, caller: Owner): boolean
      if created.dead or created.source.dead then
        return false
      end
      host.checkOwner(caller)
      if created.kind == 'window' then
        return created.source:close()
      end
      created.source:dismiss()
      return panel.retire(created)
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
  local target = {
    kind = source.kind,
    source = source.source,
    pose = pose,
    width = 0,
    height = 0,
    sizeAxis = 'fixed',
    sourceAspect = host.settings.aspect,
    priority = priority,
    title = settings.title,
    chrome = chrome,
    curve = curve,
    curveExplicit = settings.curve ~= nil,
    hidden = false,
    locked = settings.locked == true,
    lockedExplicit = settings.locked ~= nil,
    transformLocked = settings.transformLocked == true,
    transformLockedExplicit = settings.transformLocked ~= nil,
    highlighted = false,
    granted = false,
    dead = false,
    owner = owner,
    host = host,
    overrides = {},
    contour = silhouette.new(),
  }
  created = (setmetatable(target, metatable) :: unknown) :: State

  if settings.width or settings.height then
    panel.resize(created, settings.width, settings.height)
  else
    panel.resize(created, nil, host.settings.height)
  end
  return created
end

-- Marks a panel dead, releases its claim, mesh, and visibility overrides, and emits the removal event.
-- Returns false when the panel is already dead.
function panel.release(target: State): boolean
  if target.dead then
    return false
  end
  target.dead = true
  target.contour = nil
  local overrides = table.clone(target.overrides)
  table.clear(target.overrides)
  target.hidden = false
  local mesh = target.mesh
  target.mesh, target.meshKey = nil, nil
  local operations: { () -> () } = {
    function(): ()
      frame.clear(target)
    end,
    function(): ()
      drawing.clearOutline(target)
    end,
    function(): ()
      drawing.clearChildren(target)
    end,
    function(): ()
      layer.release(target)
    end,
  }
  if mesh then
    operations[#operations + 1] = function(): ()
      mesh:release()
    end
  end
  for _, override in ipairs(overrides) do
    local effect = override.effect
    override.effect = nil
    if effect then
      operations[#operations + 1] = function(): ()
        effect:dispose()
      end
    end
  end
  operations[#operations + 1] = function(): ()
    target.host.removed(target)
  end
  cleanup.run('panels release', operations)
  return true
end

-- Panel release precedes effect disposal. Owner authority remains live during release for removal listeners.
function panel.retire(target: State): boolean
  if target.dead then
    return false
  end
  local effect = target.effect
  target.effect = nil
  local ok, failure = pcall(panel.release, target)
  local disposed, disposalFailure = pcall(function(): ()
    if effect then
      effect:dispose()
    end
  end)
  if not ok then
    error(tostring(failure) .. (if disposed then '' else '; ' .. tostring(disposalFailure)), 0)
  end
  if not disposed then
    error(disposalFailure, 0)
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
    layer.release(target)
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

-- A layer copy takes the window's texture pixel for pixel, so a claim is sized by the texture, which
-- is larger than the window when the client scales it down with a viewport or a buffer scale.
function panel.textureSize(target: State): (number?, number?)
  local described: drawing.Source = target
  if described.kind ~= 'window' or described.source.dead then
    return nil, nil
  end
  local texture = described.source:getTexture()
  if not texture then
    return nil, nil
  end
  local width, height = texture:getDimensions()
  return width, height
end

-- The pixel rectangle of a window's texture that its source crop selects.
local function cropViewport(target: State, textureWidth: number, textureHeight: number): layer.Viewport
  local x, y, width, height = 0, 0, 1, 1
  local described: drawing.Source = target
  if described.kind == 'window' then
    x, y, width, height = described.source:getSourceCrop()
  end
  local left, top = math.round(x * textureWidth), math.round(y * textureHeight)
  return {
    x = left,
    y = top,
    width = math.max(1, math.round((x + width) * textureWidth) - left),
    height = math.max(1, math.round((y + height) * textureHeight) - top),
  }
end

local function sourceAspect(target: State): number
  if target.kind == 'monitor' then
    local width, height = target.source.logicalWidth, target.source.logicalHeight
    if width and height and width > 0 and height > 0 then
      return width / height
    end
  end
  local width, height = panel.sourceSize(target)
  if width and height and width > 0 and height > 0 then
    return width / height
  end
  return target.host.settings.aspect
end

function panel.resize(target: State, width: number?, height: number?)
  local aspect = sourceAspect(target)

  if not width and not height then
    error 'panels: a size needs a width, a height, or both'
  end
  local w: number = width or (height or 0) * aspect
  local h: number = height or w / aspect
  if not (w > 0) or not (h > 0) then
    error('panels: a panel is at least as large as nothing, and ' .. w .. 'x' .. h .. ' is not', 3)
  end
  target.width, target.height = w, h
  target.sizeAxis = if width and height then 'fixed' else if width then 'width' else 'height'
  target.sourceAspect = aspect
end

-- The flat quad, or the arc a positive curve gives.
function panel.raycast(
  target: State,
  origin: vector,
  direction: vector,
  backFace: boolean?
): (number?, number?, number?)
  local pixelWidth, pixelHeight = panel.sourceSize(target)
  if not pixelWidth or not pixelHeight then
    return nil, nil, nil
  end
  local polygon
  if not target.granted then
    local _, _, contour, rounded = silhouette.get(target, target.host.paint().style)
    if rounded then
      polygon = contour
    end
  end
  return shape.hit({
    polygon = polygon,
    pose = target.pose,
    width = target.width,
    height = target.height,
    pixelWidth = pixelWidth,
    pixelHeight = pixelHeight,
    backFace = backFace,
    curve = target.curve,
  }, origin, direction)
end

-- Acquires or replaces a window panel's layer claim when its source needs one.
-- A hidden panel holds none, and neither does a window showing popups or subsurfaces: a layer is composited
-- over the scene, where they are drawn, and would cover them.
function panel.claim(target: State)
  if target.dead or target.hidden or target.source.dead or target.host.settings.rendering ~= 'layer' then
    return
  end
  -- A curved window needs a compositor that submits cylinder layers; without one it draws in the scene.
  if target.kind == 'window' and target.curve > 0 and not target.host.layerCurve() then
    if target.claim then
      layer.release(target)
    end
    return
  end
  local described: drawing.Source = target
  if described.kind == 'window' and #described.source:getChildSurfaces() > 0 then
    if target.claim then
      layer.release(target)
    end
    return
  end
  local pixelWidth, pixelHeight = panel.textureSize(target)
  if not pixelWidth or not pixelHeight or pixelWidth <= 0 or pixelHeight <= 0 then
    return
  end
  if layer.needed(target, pixelWidth, pixelHeight) then
    target.host.checkOwner(target.owner)
    layer.acquire(target, pixelWidth, pixelHeight)
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
  target.host.paint()
  local aspect = sourceAspect(target)
  if aspect ~= target.sourceAspect then
    target.sourceAspect = aspect
    if target.sizeAxis == 'width' then
      target.height = target.width / aspect
    elseif target.sizeAxis == 'height' then
      target.width = target.height * aspect
    end
  end
  if target.hidden then
    if target.claim then
      layer.release(target)
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
  if target.kind ~= 'window' or target.host.settings.rendering ~= 'layer' then
    return
  end
  local textureWidth, textureHeight = panel.textureSize(target)
  if textureWidth and textureHeight then
    layer.drive(target, cropViewport(target, textureWidth, textureHeight), function(held: Layer): ()
      held:setPosition(target.pose:getPosition())
      held:setOrientation(target.pose:getOrientation())
      held:setDimensions(target.width, target.height)
      -- One shared clamp serves the layer, the hit test, and the scene mesh.
      held:setCurve(curved.curvature(target.width, target.height, target.curve, 0))
    end)
  end
end

return panel
