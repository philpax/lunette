-- Independent panel silhouettes and owner-scoped frame attachments share pure rounded primitives.

local rounded = require '@lunette-plugins/theme/rounded-geometry'
local drawing = require '@lunette-plugins/theme/drawing'
local geometry = require './geometry'

local surfaces = {}
local validate

function surfaces.attach(panel, owner, given)
  local context = panel.provider.context
  context:checkOwner(owner)
  assert(panel.live(), 'ui substitute frame: the target is dead')
  assert(not panel.frame, 'ui substitute frame: the target already has an attachment')
  local record = { style = validate(given), dead = false }
  local effect
  local function changed()
    panel.shape = nil
    drawing.clear(panel.meshes)
    drawing.clear(panel.frameMeshes)
    for _, control in panel.controls do
      drawing.clear(control.meshes)
    end
    if panel.live() then
      panel.revision += 1
      panel.cancel(nil, 'control-removed')
    end
  end
  function record.joined()
    return not record.dead and panel.live() and panel.visible and context:owns(owner)
  end
  local function invalidate()
    if record.dead then
      return
    end
    record.dead = true
    if panel.frame == record then
      panel.frame = nil
      changed()
    end
  end
  local handle = {}
  function handle.update(_, replacement)
    assert(not record.dead and panel.live() and context:owns(owner), 'ui substitute frame: the attachment is dead')
    local prepared = validate(replacement)
    local previous = record.style
    record.style = prepared
    if previous.headerHeight ~= prepared.headerHeight or previous.headerRadius ~= prepared.headerRadius then
      changed()
    elseif previous.borderThickness ~= prepared.borderThickness then
      drawing.clear(panel.frameMeshes)
    end
  end
  function handle.isJoined(_)
    return record.joined()
  end
  function handle.dispose(_)
    if record.dead and not effect then
      return
    end
    local cleaned, cleanup = pcall(invalidate)
    local released, failure = pcall(function()
      if effect then
        local previous = effect
        effect = nil
        previous:dispose()
      end
    end)
    if not cleaned then
      error(tostring(cleanup) .. (if released then '' else '; ' .. tostring(failure)), 0)
    end
    if not released then
      error(failure, 0)
    end
  end
  record.dispose = function()
    handle:dispose()
  end
  local _, acquired = context:resource(owner, function()
    panel.frame = record
    local completed, failure = pcall(changed)
    if not completed then
      panel.frame = nil
      record.dead = true
      error(failure, 0)
    end
    return table.freeze(handle), invalidate
  end)
  effect = acquired
  return handle
end

function surfaces.contour(panel, given)
  local bounds = geometry.bounds(given.bounds)
  local profile = rounded.profile(bounds, given.profile)
  local key = rounded.key(bounds, profile)
  if panel.contour and panel.contour.key == key then
    return
  end
  panel.contour = { key = key, bounds = bounds, profile = profile }
  panel.shape = nil
  drawing.clear(panel.meshes)
  for _, control in panel.controls do
    drawing.clear(control.meshes)
  end
  panel.revision += 1
  panel.cancel(nil, 'control-removed')
end

function surfaces.shape(panel)
  local target = panel.surface
  local bounds = { x = 0, y = 0, width = target.pixelWidth, height = target.pixelHeight }
  local radiusX = panel.resolved.panelRadius
  local explicit = (panel.overrides and panel.overrides.panelRadius) or panel.provider.overrides.panelRadius
  local _, sy = target.pose:getScale()
  local radiusY = if explicit ~= nil
    then explicit
    else panel.provider.radius * target.pixelHeight / (target.height * math.abs(sy))
  local profile = rounded.uniform(radiusX, radiusY)
  local frame = panel.frame
  if frame and frame.joined() then
    local square = rounded.uniform(0).topLeft
    profile =
      { topLeft = square, topRight = square, bottomRight = profile.bottomRight, bottomLeft = profile.bottomLeft }
  end
  local contour = panel.contour
  if contour then
    bounds, profile = contour.bounds, contour.profile
  end
  profile = rounded.profile(bounds, profile)
  local key = rounded.key(bounds, profile)
  if not panel.shape or panel.shape.key ~= key then
    panel.shape = {
      key = key,
      bounds = bounds,
      profile = profile,
      polygon = rounded.perimeter(bounds, profile),
      clip = geometry.intersect(rounded.safeClip(bounds, profile), {
        x = 0,
        y = 0,
        width = target.pixelWidth,
        height = target.pixelHeight,
      }),
    }
  end
  return panel.shape
end

function surfaces.contains(panel, x, y)
  return x ~= nil and y ~= nil and rounded.contains(surfaces.shape(panel).polygon, x, y)
end

function surfaces.outline(panel, pass)
  local frame = panel.frame
  if not frame or not frame.joined() then
    return
  end
  local target, style = panel.surface, frame.style
  local body = rounded.profile(
    { x = 0, y = 0, width = target.width, height = target.height },
    rounded.uniform(
      panel.resolved.panelRadius * target.width / target.pixelWidth,
      surfaces.shape(panel).profile.bottomRight.y * target.height / target.pixelHeight
    )
  )
  local header = rounded.profile(
    { x = 0, y = 0, width = target.width, height = style.headerHeight },
    rounded.uniform(style.headerRadius)
  ).topLeft
  pass:push 'transform'
  pass:transform(target.pose)
  pass:translate(0, 0, -style.borderDepth)
  pass:scale(1, -1, 1)
  pass:setShader()
  pass:setMaterial(nil)
  pass:setDepthTest 'gequal'
  pass:setDepthWrite(style.borderColor[4] >= 1)
  pass:setColor(table.unpack(style.borderColor))
  drawing.border(pass, panel.frameMeshes, {
    x = -target.width / 2,
    y = -target.height / 2 - style.headerHeight,
    width = target.width,
    height = target.height + style.headerHeight,
  }, {
    topLeft = header,
    topRight = header,
    bottomRight = body.bottomRight,
    bottomLeft = body.bottomLeft,
  }, style.borderThickness)
  pass:pop 'transform'
end

validate = function(value)
  assert(type(value) == 'table' and getmetatable(value) == nil, 'ui substitute frame: style is a plain table')
  local allowed =
    { headerHeight = true, headerRadius = true, borderThickness = true, borderDepth = true, borderColor = true }
  for key in value do
    assert(allowed[key], 'ui substitute frame: unknown style field ' .. tostring(key))
  end
  local result = {}
  for _, key in { 'headerHeight', 'headerRadius', 'borderThickness', 'borderDepth' } do
    local number = value[key]
    assert(geometry.finite(number) and number >= 0, 'ui substitute frame: dimensions are finite and nonnegative')
    assert(key ~= 'headerHeight' or number > 0, 'ui substitute frame: header height is positive')
    result[key] = number
  end
  local color = value.borderColor
  assert(type(color) == 'table' and getmetatable(color) == nil, 'ui substitute frame: color is a plain array')
  local count = 0
  for key, number in color do
    assert(
      type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= 4,
      'ui substitute frame: color has four channels'
    )
    assert(geometry.finite(number) and number >= 0 and number <= 1, 'ui substitute frame: color channels are in [0, 1]')
    count += 1
  end
  assert(count == 4, 'ui substitute frame: color has four channels')
  result.borderColor = table.freeze(table.clone(color))
  return table.freeze(result)
end

return surfaces
