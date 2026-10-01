-- One panel over a window or a monitor: its geometry, layer claim, and drawing.
--
-- A panel reaches its provider activation through the host it is made with,
-- not through a module-global registry, so separate activations share nothing.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local surface = require '@lunette-contracts/surface'
local quad = require '@lunette-contracts/quad'
local layer = require '@lunette-plugins/panels/layer'

local panel = {}

export type Owner = contracts.Owner
export type Panel = contracts.Panel
export type Options = contracts.Options

-- The resolved options of the activation that made a panel: its style, and
-- the priority, height, and aspect ratio a panel takes when it is given none
-- and its source has no size.
export type Settings = {
  read style: contracts.Style,
  read priority: number,
  read height: number,
  read aspect: number,
}

-- What a panel needs from the activation that made it.
export type Host = {
  -- Whether the activation is still live.
  read active: () -> boolean,
  -- Raises unless the owner is still a live owner of this activation.
  read checkOwner: (Owner) -> (),
  read settings: Settings,
  -- The activation's opaque shader, or nil when none can be made.
  read opaqueShader: () -> Shader?,
  -- Called once a panel is dead and its claim released.
  read removed: (State) -> (),
}

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
  host: Host,
  -- The owner's effect that holds this panel, once the acquisition returns.
  effect: plugin.Effect?,
  read setPose: (surface.Surface, Mat4) -> (),
  read setSize: (surface.Surface, number?, number?) -> (),
  read raycast: (surface.Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read sink: (surface.Surface) -> lunette.Sink?,
  read sourceSize: (Panel) -> (number?, number?),
  read update: (Panel) -> (),
  read draw: (Panel, Pass) -> (),
  read drawChrome: (Panel, Pass) -> (),
  read destroy: (Panel, Owner) -> boolean,
}
export type Source =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }
export type State = MutablePanel & Source

-- Creates a panel's state without registering it or acquiring a claim.
function panel.new(host: Host, owner: Owner, source: Source, options: Options?): State
  if source.source == nil then
    error('panels: a panel is over a source, and nil is not one', 4)
  end
  local settings: Options = options or {}
  local created: State
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
    raycast = function(_self: surface.Surface, origin: vector, direction: vector, backFace: boolean?)
      return panel.raycast(created, origin, direction, backFace)
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
      panel.draw(created, pass)
    end,
    drawChrome = function(_self: Panel, pass: Pass)
      panel.drawChrome(created, pass)
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
  local chrome = settings.chrome ~= false
  local noClaim: layer.Claim? = nil
  local noSize: number? = nil
  local noEffect: plugin.Effect? = nil
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
      highlighted = false,
      granted = false,
      dead = false,
      claim = noClaim,
      appliedWidth = noSize,
      appliedHeight = noSize,
      owner = owner,
      host = host,
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
      highlighted = false,
      granted = false,
      dead = false,
      claim = noClaim,
      appliedWidth = noSize,
      appliedHeight = noSize,
      owner = owner,
      host = host,
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

-- Marks a panel dead, releases its claim, and tells the host. Answers false
-- for a panel that was already dead.
function panel.release(target: State): boolean
  if target.dead then
    return false
  end
  target.dead = true
  target.granted = false
  local claim = target.claim
  target.claim = nil
  if claim then
    claim:release()
  end
  target.host.removed(target)
  return true
end

-- Ends a panel and then disposes its owner's effect, so the effect does not
-- outlive it. The release runs here rather than as the effect's inverse: an
-- owner's authority is withheld while one of its inverses runs, and removal
-- listeners, the panel's own owner among them, must hear the removal as live
-- owners. A release that fails raises to the caller, and the effect's inverse
-- then has nothing left to do.
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
  return quad.hit({
    pose = target.pose,
    width = target.width,
    height = target.height,
    pixelWidth = pixelWidth,
    pixelHeight = pixelHeight,
    backFace = backFace,
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
function panel.claim(target: State)
  if target.dead or target.source.dead then
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

function panel.update(target: State)
  if target.dead then
    return
  end
  if target.source.dead then
    panel.retire(target)
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
    layer.drive(target, pixelWidth, pixelHeight)
  end
end

function panel.draw(target: State, pass: Pass)
  local source: lunette.Textured = target.source
  if target.dead or source.dead then
    return
  end

  if target.chrome then
    panel.drawChrome(target, pass)
  end
  if target.granted then
    return
  end

  local texture: Texture | false
  local shader: Shader?
  local described: Source = target
  if described.kind == 'window' then
    local window = described.source
    texture = window:getTexture()
    if window.opaque then
      shader = target.host.opaqueShader()
    end
  else
    texture = described.source:getTexture()
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
end

function panel.drawChrome(target: State, pass: Pass)
  local style = target.host.settings.style
  local color = target.highlighted and style.borderHighlightColor or style.borderColor

  pass:setColor(color[1], color[2], color[3], color[4])
  local borderTransform = lovr.math
    .newMat4()
    :set(target.pose)
    :translate(0, 0, -style.borderDepth)
    :scale(target.width + style.borderThickness * 2, target.height + style.borderThickness * 2, 1)
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
end

return panel
