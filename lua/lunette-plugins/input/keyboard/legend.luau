-- Draws a key legend for a custom keyboard drawing hook.
local hooks = require './hooks'
local bounds = require './legend-bounds'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'
local passState = require '@lunette-plugins/graphics/pass-state'

local function legend(pass: Pass, key: hooks.RenderedKey, state: hooks.KeyState, boundFont: Font?): ()
  local style = state.style
  local font = boundFont or style.font
  local clip = geometry.safeClip(bounds.faceBounds(key, style), geometry.uniform(style.keyRadius))
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

return { legend = legend }
