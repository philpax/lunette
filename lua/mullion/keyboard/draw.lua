-- Drawing a keyboard: a plate, a plane per key, and a legend on each.
--
-- Drawing uses `Pass:plane` and `Pass:text` and nothing else, which is why this
-- half stays apart from the object that decides what to draw. It receives the
-- keys and the state to colour them by rather than the keyboard itself, so it
-- does not depend on where either came from.
--
-- Everything is placed relative to a pose. The key geometry runs from the
-- board's top-left with y downwards and a plane's own y runs upwards from its
-- middle, which is the conversion each key's transform carries.

local layout = require '@mullion/keyboard/layout'

local draw = {}

-- The colours and depths a keyboard is drawn with. `mullion.keyboard`'s
-- `Style` carries the measurements as well, and includes everything here.
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

-- Which of the three colours a key takes.
export type KeyState = {
  -- Whether the key's own modifier is down. A key that is not a modifier is
  -- never held.
  read held: (layout.RenderedKey) -> boolean,
  -- Whether a pointer is on it.
  read hovered: (layout.RenderedKey) -> boolean,
}

-- Draws the plate, then every key, then the legends.
--
-- `width` and `height` are the board's extent in metres, as
-- `layout.extentOf` answers it.
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
  -- The extent rides in the transform's scale. `luax_readmat4` consumes a whole
  -- `Mat4` and reads the argument after it as the draw style, so a plane placed
  -- by matrix takes its size from that matrix and not from two more arguments.
  local plate: Mat4 = lovr.math.newMat4()
  plate:set(pose)
  plate:translate(0, 0, -style.plateDepth)
  plate:scale(width + style.margin * 2, height + style.margin * 2, 1)
  pass:plane(plate, 'fill', 1, 1)

  for _, key: layout.RenderedKey in ipairs(keys) do
    local x = key.x + key.width / 2 - width / 2
    local y = height / 2 - (key.y + key.height / 2)

    local keyColor = style.keyColor
    if state.held(key) then
      keyColor = style.heldColor
    end
    -- After the held colour, so a key under the pointer stays distinguishable
    -- as hovered even when its modifier is already down.
    if state.hovered(key) then
      keyColor = style.hoverColor
    end
    pass:setColor(keyColor[1], keyColor[2], keyColor[3], keyColor[4])

    local face: Mat4 = lovr.math.newMat4()
    face:set(pose)
    face:translate(x, y, 0)
    face:scale(key.width - style.gap, key.height - style.gap, 1)
    pass:plane(face, 'fill', 1, 1)

    local legend = style.legendColor
    pass:setColor(legend[1], legend[2], legend[3], legend[4])
    local text: Mat4 = lovr.math.newMat4()
    text:set(pose)
    text:translate(x, y, style.legendDepth)
    text:scale(vector.pack(style.legendHeight))
    pass:text(key.legend, text, 0, 'center', 'middle')
  end

  pass:setColor(1, 1, 1, 1)
end

return draw
