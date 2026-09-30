-- Keyboard drawing.
--
-- Drawing is independent of the service registry. It receives the complete
-- render state and uses only the two pass operations needed by a keyboard.

local layout = require '@lunette-plugins/keyboard/layout'

local draw = {}

export type Appearance = {
  read gap: number,
  read plateDepth: number,
  read legendDepth: number,
  read margin: number,
  read plateColor: { number },
  read keyColor: { number },
  read heldColor: { number },
  read hoverColor: { number },
  read legendColor: { number },
  read legendHeight: number,
}

export type KeyState = {
  read held: (layout.RenderedKey) -> boolean,
  read hovered: (layout.RenderedKey) -> boolean,
}

function draw.keyboard(
  pass: Pass,
  pose: Mat4,
  keys: { layout.RenderedKey },
  width: number,
  height: number,
  style: Appearance,
  state: KeyState
): ()
  local color = style.plateColor
  pass:setColor(color[1], color[2], color[3], color[4])

  local plate = lovr.math.newMat4()
  plate:set(pose)
  plate:translate(0, 0, -style.plateDepth)
  plate:scale(width + style.margin * 2, height + style.margin * 2, 1)
  pass:plane(plate, 'fill', 1, 1)

  for _, key in ipairs(keys) do
    local x = key.x + key.width / 2 - width / 2
    local y = height / 2 - (key.y + key.height / 2)
    local keyColor = style.keyColor
    if state.held(key) then
      keyColor = style.heldColor
    end
    if state.hovered(key) then
      keyColor = style.hoverColor
    end
    pass:setColor(keyColor[1], keyColor[2], keyColor[3], keyColor[4])

    local face = lovr.math.newMat4()
    face:set(pose)
    face:translate(x, y, 0)
    face:scale(key.width - style.gap, key.height - style.gap, 1)
    pass:plane(face, 'fill', 1, 1)

    local legend = style.legendColor
    pass:setColor(legend[1], legend[2], legend[3], legend[4])
    local text = lovr.math.newMat4()
    text:set(pose)
    text:translate(x, y, style.legendDepth)
    text:scale(vector.pack(style.legendHeight))
    pass:text(key.legend, text, 0, 'center', 'middle')
  end

  pass:setColor(1, 1, 1, 1)
end

return draw
