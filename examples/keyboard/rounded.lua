-- The built-in keyboard with rounded keys and nothing else changed.
--
-- `drawKey` receives each key, its state, and the default drawing. This hook
-- draws its own face and keeps the default legend. To use it, put it in
-- main.lua's patch in place of split.lua.

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
