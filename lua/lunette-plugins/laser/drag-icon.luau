-- Draws the icon of the drag a laser's seat carries at the end of its beam, facing the hand.
-- The icon is sized in the hovered panel's metres per surface pixel, remembered while the beam is off every panel,
-- and its top-left corner sits where the client placed it relative to the pointer.

local lunette = require '@lunette'
local contracts = require '@lunette-contracts/laser'
local clientPixels = require '@lunette-plugins/client-pixels'
local passState = require '@lunette-plugins/pass-state'

local dragIcon = {}

-- Metres per surface pixel before the beam has hovered a panel: a thousand-pixel window a metre wide.
dragIcon.FALLBACK_SCALE = 0.001

-- One laser's icon geometry. The mesh carries the crop in its texture coordinates and is rebuilt when it changes.
export type State = {
  scale: number,
  mesh: Mesh?,
  meshCrop: string?,
}

function dragIcon.new(): State
  return { scale = dragIcon.FALLBACK_SCALE, mesh = nil, meshCrop = nil }
end

-- Remembers the scale of the panel the beam hovers, when the panel shows a source measured in pixels.
function dragIcon.observe(state: State, hovered: contracts.Surface?): ()
  if not hovered or hovered.kind == nil or not hovered.width then
    return
  end
  local pixels = hovered.source.width
  local scale = if pixels > 0 then hovered.width / pixels else 0
  if scale > 0 and scale < math.huge then
    state.scale = scale
  end
end

function dragIcon.release(state: State): ()
  local mesh = state.mesh
  state.mesh, state.meshCrop = nil, nil
  if mesh then
    mesh:release()
  end
end

local function cropMesh(state: State, x: number, y: number, width: number, height: number): Mesh
  local key = `{x},{y},{width},{height}`
  local current = state.mesh
  if current and state.meshCrop == key then
    return current
  end
  local right, bottom = x + width, y + height
  local vertices = {
    { -0.5, 0.5, 0, 0, 0, 1, x, y },
    { -0.5, -0.5, 0, 0, 0, 1, x, bottom },
    { 0.5, 0.5, 0, 0, 0, 1, right, y },
    { 0.5, -0.5, 0, 0, 0, 1, right, bottom },
  }
  local made = lovr.graphics.newMesh(#vertices)
  local ok, failure = pcall(function(): ()
    made:setVertices(vertices)
    made:setIndices { 1, 2, 3, 3, 2, 4 }
  end)
  if not ok then
    made:release()
    error(failure, 0)
  end
  dragIcon.release(state)
  state.mesh, state.meshCrop = made, key
  return made
end

-- Draws `drag`'s icon with its pointer at `at`, facing `origin`. A drag without an icon draws nothing.
function dragIcon.draw(
  state: State,
  pass: Pass,
  drag: lunette.Drag,
  at: vector,
  origin: vector,
  shaders: clientPixels.Shaders
): ()
  local texture = drag:getTexture()
  if not texture or drag.width <= 0 or drag.height <= 0 then
    return
  end
  local toward = origin - at
  if vector.magnitude(toward) <= 0 then
    return
  end
  local shader = shaders.choose(drag.opaque)
  if not shader then
    return
  end
  local mesh = cropMesh(state, drag:getSourceCrop())
  local scale = state.scale
  local width, height = drag.width * scale, drag.height * scale
  -- `target` turns +Z from the second point toward the first, so the plane faces the hand; straight up or down,
  -- the world's up cannot orient it, so its depth axis does.
  local facing = vector.normalize(toward)
  local up = if math.abs(facing.y) > 0.999 then vector.pack(0, 0, -1) else vector.pack(0, 1, 0)
  local pose = lovr.math
    .newMat4()
    :target(at, at - toward, up)
    :translate(drag.x * scale + width / 2, -(drag.y * scale + height / 2), 0)
    :scale(width, height, 1)
  passState.withRestore(pass, function()
    pass:setDepthTest()
    pass:setDepthWrite(false)
    pass:setColor(1, 1, 1, 1)
    pass:setBlendMode('alpha', 'premultiplied')
    pass:setShader(shader)
    pass:setMaterial(texture)
    pass:draw(mesh, pose)
  end)
end

return dragIcon
