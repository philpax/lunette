-- Retains a panel's emitted contour, safe content clip, and target-owned frame attachment.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local vocabulary = require '@lunette-contracts/vocabulary'
local records = require './panel-state'
local rounded = require '@lunette-plugins/theme/rounded-geometry'
local frameStyle = require '@lunette-plugins/theme/frame-style'
local drawing = require '@lunette-plugins/theme/drawing'
local geometry = require './geometry'
local passState = require '@lunette-plugins/pass-state'
local cleanup = require './cleanup'

local panelGeometry = {}

function panelGeometry.bounds(state: records.Panel): ui.Bounds
  return { x = 0, y = 0, width = state.logicalWidth, height = state.logicalHeight }
end

function panelGeometry.joined(state: records.Panel): boolean
  return state.frame ~= nil and state.frame.joined()
end

function panelGeometry.prepare(state: records.Panel): records.Shape
  local bounds = panelGeometry.bounds(state)
  local custom = state.contour
  local explicit = state.overrides and state.overrides.panelRadius ~= nil or state.providerTheme.panelRadius ~= nil
  local radius = rounded.uniform(state.theme.panelRadius, if explicit then state.theme.panelRadius else state.radiusY)
  if panelGeometry.joined(state) then
    radius = {
      topLeft = { x = 0, y = 0 },
      topRight = { x = 0, y = 0 },
      bottomRight = radius.bottomRight,
      bottomLeft = radius.bottomLeft,
    }
  end
  local contourBounds = if custom then custom.bounds else bounds
  local profile = rounded.profile(contourBounds, if custom then custom.profile else radius)
  local key = rounded.key(contourBounds, profile, bounds)
  local previous = state.shape
  if previous and previous.key == key then
    return previous
  end
  drawing.clear(state.frameMeshes)
  drawing.clear(state.measurements.faces)
  for _, control in state.controls do
    drawing.clear(control.measurements.faces)
  end
  local shape: records.Shape = {
    key = key,
    bounds = contourBounds,
    profile = profile,
    polygon = rounded.clip(rounded.perimeter(contourBounds, profile), bounds),
    clip = geometry.intersect(bounds, rounded.safeClip(contourBounds, profile))
      or { x = 0, y = 0, width = 0, height = 0 },
  }
  state.shape = shape
  return shape
end

function panelGeometry.attach(
  state: records.Panel,
  owner: plugin.Owner,
  given: vocabulary.FrameStyle,
  changed: (boolean) -> ()
): vocabulary.FrameAttachment
  state.context:checkOwner(owner)
  assert(not state.dead and state.context:active() and state.context:owns(state.owner), 'ui frame: target is dead')
  local style = frameStyle.validate(given)
  assert(state.frame == nil, 'ui frame: target already has an attachment')
  local disposed = false
  local inverse: plugin.Effect? = nil
  local function live(): boolean
    return not disposed and not state.dead and state.context:active() and state.context:owns(owner)
  end
  local function dispose(): ()
    if disposed then
      return
    end
    disposed = true
    state.frame = nil
    local effect = inverse
    inverse = nil
    cleanup.run('ui frame cleanup', {
      function(): ()
        drawing.clear(state.frameMeshes)
      end,
      function(): ()
        changed(true)
      end,
      function(): ()
        if effect then
          effect:dispose()
        end
      end,
    })
  end
  local attachment: vocabulary.FrameAttachment = {
    update = function(_self: vocabulary.FrameAttachment, givenStyle: vocabulary.FrameStyle): ()
      assert(live(), 'ui frame: attachment or target is dead')
      local parsed = frameStyle.validate(givenStyle)
      if frameStyle.equal(style, parsed) then
        return
      end
      local geometryChanged = style.headerHeight ~= parsed.headerHeight or style.headerRadius ~= parsed.headerRadius
      drawing.clear(state.frameMeshes)
      style = parsed
      local current = state.frame
      if current then
        current.style = style
      end
      changed(geometryChanged)
    end,
    isJoined = function(_self: vocabulary.FrameAttachment): boolean
      return live() and state.visible
    end,
    dispose = function(_self: vocabulary.FrameAttachment): ()
      dispose()
    end,
  }
  state.frame = {
    style = style,
    joined = function(): boolean
      return attachment:isJoined()
    end,
    dispose = dispose,
  }
  local ok, failure = pcall(function(): ()
    inverse = state.context:acquire(owner, function(): () -> ()
      return dispose
    end)
    changed(true)
  end)
  if not ok then
    pcall(dispose)
    error(failure, 0)
  end
  return table.freeze(attachment)
end

function panelGeometry.drawFrame(state: records.Panel, pass: Pass): ()
  local frame = state.frame
  if not frame or not frame.joined() then
    return
  end
  local style = frame.style
  local body = panelGeometry.prepare(state).profile
  local sx, sy = state.width / state.logicalWidth, state.height / state.logicalHeight
  local header = rounded.profile(
    { x = 0, y = 0, width = state.width, height = style.headerHeight },
    rounded.uniform(style.headerRadius)
  )
  local bounds = {
    x = -state.width / 2,
    y = -state.height / 2 - style.headerHeight,
    width = state.width,
    height = state.height + style.headerHeight,
  }
  local profile: rounded.Profile = {
    topLeft = header.topLeft,
    topRight = header.topRight,
    bottomRight = { x = body.bottomRight.x * sx, y = body.bottomRight.y * sy },
    bottomLeft = { x = body.bottomLeft.x * sx, y = body.bottomLeft.y * sy },
  }
  passState.withRestore(pass, function(): ()
    pass:setShader()
    pass:setMaterial(nil)
    pass:setCullMode 'none'
    pass:setDepthTest 'gequal'
    pass:setDepthWrite(style.borderColor[4] == 1)
    pass:setColor(style.borderColor[1], style.borderColor[2], style.borderColor[3], style.borderColor[4])
    pass:transform(state.pose)
    pass:translate(0, 0, -style.borderDepth)
    pass:scale(1, -1, 1)
    drawing.border(pass, state.frameMeshes, bounds, profile, style.borderThickness)
  end)
end

return panelGeometry
