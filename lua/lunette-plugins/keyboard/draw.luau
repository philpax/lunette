-- Draws keyboard plates, faces, and legends.
local keyboard = require '@lunette-contracts/keyboard'
local board = require '@lunette-plugins/keyboard/board'
local passState = require '@lunette-plugins/pass-state'

local draw = {}

function draw.plate(pass: Pass, pose: Mat4, width: number, height: number, style: keyboard.Style): ()
  local color = style.plateColor
  pass:setColor(color[1], color[2], color[3], color[4])
  local plate = lovr.math.newMat4()
  plate:set(pose)
  plate:translate(0, 0, -style.plateDepth)
  plate:scale(width + style.margin * 2, height + style.margin * 2, 1)
  pass:plane(plate, 'fill', 1, 1)
  pass:setColor(1, 1, 1, 1)
end

-- Hover color takes precedence over the held color.
function draw.faceColor(state: board.KeyState): { read [number]: number }
  local style = state.style
  if state.hovered then
    return style.hoverColor
  elseif state.held then
    return style.heldColor
  end
  return style.keyColor
end

function draw.face(pass: Pass, key: board.RenderedKey, state: board.KeyState): ()
  local color = draw.faceColor(state)
  pass:setColor(color[1], color[2], color[3], color[4])
  local face = lovr.math.newMat4()
  face:set(state.pose)
  face:scale(key.width - state.style.gap, key.height - state.style.gap, 1)
  pass:plane(face, 'fill', 1, 1)
  pass:setColor(1, 1, 1, 1)
end

function draw.legend(pass: Pass, key: board.RenderedKey, state: board.KeyState): ()
  local style = state.style
  local color = style.legendColor
  passState.withRestore(pass, function()
    pass:setFont(style.font)
    pass:setDepthWrite(false)
    pass:setColor(color[1], color[2], color[3], color[4])
    local text = lovr.math.newMat4()
    text:set(state.pose)
    text:translate(0, 0, style.legendDepth)
    text:scale(vector.pack(style.legendHeight))
    pass:text(key.legend, text, 0, 'center', 'middle')
  end)
end

function draw.key(pass: Pass, key: board.RenderedKey, state: board.KeyState): ()
  draw.face(pass, key, state)
  draw.legend(pass, key, state)
end

function draw.keyPose(pose: Mat4, key: board.RenderedKey, width: number, height: number): Mat4
  local centre = lovr.math.newMat4()
  centre:set(pose)
  centre:translate(key.x + key.width / 2 - width / 2, height / 2 - (key.y + key.height / 2), 0)
  return centre
end

return draw
