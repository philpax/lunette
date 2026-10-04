-- The `drawKey` hook replaces each key face and preserves the default legend.

local keyboard = require '@lunette-plugins/keyboard'
local drawing = require '@lunette-plugins/keyboard/draw'

return keyboard.define {
  name = 'rounded-keyboard',
  drawKey = function(pass, key, state, _base)
    local style = state.style
    local color = drawing.faceColor(state)
    pass:setColor(color[1], color[2], color[3], color[4])
    local face = lovr.math.mat4(state.pose):scale(key.width - style.gap, key.height - style.gap, style.plateDepth)
    pass:roundrect(face, style.gap)
    drawing.legend(pass, key, state)
  end,
}
