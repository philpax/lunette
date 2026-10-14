-- Internal face bounds shared by the keyboard legend extension and its private drawing.
local hooks = require './hooks'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'

local function faceBounds(key: hooks.RenderedKey, style: hooks.Style): geometry.Bounds
  local width, height = math.max(0, key.width - style.gap), math.max(0, key.height - style.gap)
  return { x = -width / 2, y = -height / 2, width = width, height = height }
end

return { faceBounds = faceBounds }
