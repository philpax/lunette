-- Draws keyboard plates and faces, and places complete keys.
local hooks = require '../hooks'
local bounds = require '../legend-bounds'
local legend = require '../legend'
local passState = require '@lunette-plugins/graphics/pass-state'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'
local drawing = require '@lunette-plugins/graphics/rounded-drawing'

local draw = {}
local faceColor: (hooks.KeyState) -> { read [number]: number }

function draw.plate(pass: Pass, cache: drawing.Cache, pose: Mat4, width: number, height: number, style: hooks.Style): ()
  local color = style.plateColor
  local plateWidth, plateHeight = width + style.margin * 2, height + style.margin * 2
  local plateBounds = { x = -plateWidth / 2, y = -plateHeight / 2, width = plateWidth, height = plateHeight }
  passState.withRestore(pass, function(): ()
    pass:setColor(color[1], color[2], color[3], color[4])
    pass:transform(pose)
    pass:translate(0, 0, -style.plateDepth)
    pass:scale(1, -1, 1)
    drawing.face(pass, cache, plateBounds, geometry.uniform(style.backingRadius))
  end)
  pass:setColor(1, 1, 1, 1)
end

function draw.face(pass: Pass, cache: drawing.Cache, key: hooks.RenderedKey, state: hooks.KeyState): ()
  local color = faceColor(state)
  passState.withRestore(pass, function(): ()
    pass:setColor(color[1], color[2], color[3], color[4])
    pass:transform(state.pose)
    pass:scale(1, -1, 1)
    drawing.face(pass, cache, bounds.faceBounds(key, state.style), geometry.uniform(state.style.keyRadius))
  end)
  pass:setColor(1, 1, 1, 1)
end

function draw.key(pass: Pass, cache: drawing.Cache, key: hooks.RenderedKey, state: hooks.KeyState, boundFont: Font): ()
  draw.face(pass, cache, key, state)
  legend.legend(pass, key, state, boundFont)
end

function draw.keyPose(pose: Mat4, key: hooks.RenderedKey, width: number, height: number): Mat4
  local centre = lovr.math.newMat4()
  centre:set(pose)
  centre:translate(key.x + key.width / 2 - width / 2, height / 2 - (key.y + key.height / 2), 0)
  return centre
end

faceColor = function(state: hooks.KeyState): { read [number]: number }
  local style = state.style
  if state.hovered then
    return style.hoverColor
  elseif state.held then
    return style.heldColor
  end
  return style.keyColor
end

return draw
