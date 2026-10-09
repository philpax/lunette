-- Draws the header face and safe title above the target-owned joined outline.
local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local rounded = require '@lunette-plugins/theme/rounded-geometry'
local drawing = require '@lunette-plugins/theme/drawing'
local passState = require '@lunette-plugins/pass-state'
local depth = require './depth'
local vocabulary = require '@lunette-contracts/vocabulary'

local titlebarDraw = {}

function titlebarDraw.profile(width: number, height: number, radius: number, joined: boolean): rounded.Profile
  local profile = rounded.profile({ x = 0, y = 0, width = width, height = height }, rounded.uniform(radius))
  return if joined
    then {
      topLeft = profile.topLeft,
      topRight = profile.topRight,
      bottomRight = { x = 0, y = 0 },
      bottomLeft = { x = 0, y = 0 },
    }
    else profile
end

function titlebarDraw.render(
  pass: Pass,
  cache: drawing.Cache,
  target: vocabulary.Surface,
  pose: Mat4,
  style: ui.TitlebarStyle,
  title: string,
  reserved: number,
  highlighted: boolean,
  joined: boolean
): ()
  local width, height, targetPose = target.width, target.height, target.pose
  if not width or not height or not targetPose then
    return
  end
  local bounds = { x = -width / 2, y = -style.barHeight / 2, width = width, height = style.barHeight }
  local profile = titlebarDraw.profile(width, style.barHeight, style.cornerRadius, joined)
  passState.withRestore(pass, function(): ()
    pass:setShader()
    pass:setMaterial(nil)
    pass:setFont(style.font)
    pass:setCullMode 'none'
    pass:setDepthTest 'gequal'
    if not joined then
      local border = if highlighted then style.borderHighlightColor else style.borderColor
      pass:setColor(border[1], border[2], border[3], border[4])
      pass:setDepthWrite(border[4] == 1)
      pass:push 'transform'
      pass:transform(targetPose)
      pass:translate(0, 0, -style.borderDepth)
      pass:scale(1, -1, 1)
      drawing.border(
        pass,
        cache,
        { x = -width / 2, y = -height / 2, width = width, height = height },
        rounded.uniform(0),
        style.borderThickness
      )
      pass:pop 'transform'
    end
    local background = if highlighted then style.barHighlightColor else style.barColor
    pass:setColor(background[1], background[2], background[3], background[4])
    pass:setDepthWrite(background[4] == 1)
    pass:push 'transform'
    pass:transform(pose)
    pass:scale(1, -1, 1)
    drawing.face(pass, cache, bounds, profile)
    pass:pop 'transform'
    if width <= reserved or title == '' then
      return
    end
    local safe = rounded.safeClip(bounds, profile)
    local right = math.min(safe.x + safe.width, width / 2 - reserved)
    local available = right - safe.x
    if available <= 0 or safe.height <= 0 then
      return
    end
    pass:setDepthWrite(false)
    local foreground = style.titleColor
    pass:setColor(foreground[1], foreground[2], foreground[3], foreground[4])
    local fontHeight = style.font:getHeight()
    assert(fontHeight > 0 and fontHeight < math.huge, 'ui titlebar: font height is finite and positive')
    local scale = math.min(style.titleHeight, safe.height) / fontHeight
    local shown = title:gsub('[\r\n]', ' ')
    if style.font:getWidth(shown) * scale > available then
      local suffix = '…'
      if style.font:getWidth(suffix) * scale > available then
        return
      end
      local prefix = ''
      local boundaries = lunette.textBoundaries(shown)
      for index = 2, #boundaries do
        local candidate = shown:sub(1, boundaries[index] - 1)
        if style.font:getWidth(candidate .. suffix) * scale <= available then
          prefix = candidate
        end
      end
      shown = prefix .. suffix
    end
    pass:text(
      shown,
      lovr.math
        .mat4(pose)
        :translate(safe.x + available / 2, -safe.y - safe.height / 2, depth.layer)
        :scale(vector.pack(scale)),
      available / scale,
      'center',
      'middle'
    )
  end)
end

return titlebarDraw
