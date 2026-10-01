-- Keyboard drawing.
--
-- Drawing is independent of the keyboard's state. It receives the plate's
-- pose and size, and each key with the state it is drawn in, and uses only
-- the pass operations a keyboard needs. `key` is the default the `drawKey`
-- hook receives as its base; `face` and `legend` are its two halves, so a
-- hook that draws its own face can keep the default legend.

local keyboard = require '@lunette-contracts/keyboard'
local board = require '@lunette-plugins/keyboard/board'

local draw = {}

-- The plate behind the keys, `width` by `height` metres plus the margin.
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

-- The colour a key's face has in its state: hovered over held over plain.
function draw.faceColor(state: board.KeyState): { number }
  local style = state.style
  if state.hovered then
    return style.hoverColor
  elseif state.held then
    return style.heldColor
  end
  return style.keyColor
end

-- A key's face: a flat rectangle, inset by the style's gap.
function draw.face(pass: Pass, key: board.RenderedKey, state: board.KeyState): ()
  local color = draw.faceColor(state)
  pass:setColor(color[1], color[2], color[3], color[4])
  local face = lovr.math.newMat4()
  face:set(state.pose)
  face:scale(key.width - state.style.gap, key.height - state.style.gap, 1)
  pass:plane(face, 'fill', 1, 1)
  pass:setColor(1, 1, 1, 1)
end

-- A key's legend, just in front of its face.
function draw.legend(pass: Pass, key: board.RenderedKey, state: board.KeyState): ()
  local style = state.style
  local color = style.legendColor
  pass:setColor(color[1], color[2], color[3], color[4])
  local text = lovr.math.newMat4()
  text:set(state.pose)
  text:translate(0, 0, style.legendDepth)
  text:scale(vector.pack(style.legendHeight))
  pass:text(key.legend, text, 0, 'center', 'middle')
  pass:setColor(1, 1, 1, 1)
end

-- One key: its face and then its legend. This is the base `drawKey`
-- receives.
function draw.key(pass: Pass, key: board.RenderedKey, state: board.KeyState): ()
  draw.face(pass, key, state)
  draw.legend(pass, key, state)
end

-- The centre of a key's face on a plate at `pose`, `width` by `height`.
function draw.keyPose(pose: Mat4, key: board.RenderedKey, width: number, height: number): Mat4
  local centre = lovr.math.newMat4()
  centre:set(pose)
  centre:translate(key.x + key.width / 2 - width / 2, height / 2 - (key.y + key.height / 2), 0)
  return centre
end

return draw
