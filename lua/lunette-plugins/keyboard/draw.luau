-- Draws keyboard plates, faces, and legends.
local keyboard = require '@lunette-contracts/keyboard'
local board = require '@lunette-plugins/keyboard/board'
local passState = require '@lunette-plugins/pass-state'
local geometry = require '@lunette-plugins/theme/rounded-geometry'
local drawing = require '@lunette-plugins/theme/drawing'

local draw = {}
local faceBounds: (board.RenderedKey, keyboard.Style) -> geometry.Bounds

function draw.plate(
  pass: Pass,
  cache: drawing.Cache,
  pose: Mat4,
  width: number,
  height: number,
  style: keyboard.Style
): ()
  local color = style.plateColor
  local plateWidth, plateHeight = width + style.margin * 2, height + style.margin * 2
  local bounds = { x = -plateWidth / 2, y = -plateHeight / 2, width = plateWidth, height = plateHeight }
  passState.withRestore(pass, function(): ()
    pass:setColor(color[1], color[2], color[3], color[4])
    pass:transform(pose)
    pass:translate(0, 0, -style.plateDepth)
    pass:scale(1, -1, 1)
    drawing.face(pass, cache, bounds, geometry.uniform(style.backingRadius))
  end)
  pass:setColor(1, 1, 1, 1)
end

function draw.faceColor(state: board.KeyState): { read [number]: number }
  local style = state.style
  if state.hovered then
    return style.hoverColor
  elseif state.held then
    return style.heldColor
  end
  return style.keyColor
end

function draw.face(pass: Pass, cache: drawing.Cache, key: board.RenderedKey, state: board.KeyState): ()
  local color = draw.faceColor(state)
  passState.withRestore(pass, function(): ()
    pass:setColor(color[1], color[2], color[3], color[4])
    pass:transform(state.pose)
    pass:scale(1, -1, 1)
    drawing.face(pass, cache, faceBounds(key, state.style), geometry.uniform(state.style.keyRadius))
  end)
  pass:setColor(1, 1, 1, 1)
end

function draw.legend(pass: Pass, key: board.RenderedKey, state: board.KeyState, boundFont: Font?): ()
  local style = state.style
  local font = boundFont or style.font
  local bounds = faceBounds(key, style)
  local clip = geometry.safeClip(bounds, geometry.uniform(style.keyRadius))
  if clip.width == 0 or clip.height == 0 then
    return
  end
  local fontHeight, fontWidth = font:getHeight(), font:getWidth(key.legend)
  local lines = font:getLines(key.legend, 0)
  local height = fontHeight + math.max(0, #lines - 1) * fontHeight * font:getLineSpacing()
  assert(fontHeight > 0 and height > 0 and height < math.huge, 'keyboard legend: invalid font height')
  assert(fontWidth >= 0 and fontWidth < math.huge, 'keyboard legend: invalid font width')
  local scale = math.min(style.legendHeight / fontHeight, clip.height / height)
  if fontWidth > 0 then
    scale = math.min(scale, clip.width / fontWidth)
  end
  local color = style.legendColor
  passState.withRestore(pass, function(): ()
    pass:setFont(font)
    pass:setDepthWrite(false)
    pass:setColor(color[1], color[2], color[3], color[4])
    local text = lovr.math.newMat4()
    text:set(state.pose)
    text:translate(clip.x + clip.width / 2, -(clip.y + clip.height / 2), style.legendDepth)
    text:scale(vector.pack(scale))
    pass:text(key.legend, text, 0, 'center', 'middle')
  end)
end

function draw.key(pass: Pass, cache: drawing.Cache, key: board.RenderedKey, state: board.KeyState, boundFont: Font): ()
  draw.face(pass, cache, key, state)
  draw.legend(pass, key, state, boundFont)
end

function draw.keyPose(pose: Mat4, key: board.RenderedKey, width: number, height: number): Mat4
  local centre = lovr.math.newMat4()
  centre:set(pose)
  centre:translate(key.x + key.width / 2 - width / 2, height / 2 - (key.y + key.height / 2), 0)
  return centre
end

faceBounds = function(key: board.RenderedKey, style: keyboard.Style): geometry.Bounds
  local width, height = math.max(0, key.width - style.gap), math.max(0, key.height - style.gap)
  return { x = -width / 2, y = -height / 2, width = width, height = height }
end

return draw
