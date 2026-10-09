-- Draws declared logical geometry beneath the caller's panel-to-world transform.
-- Hooks are supplied provider → panel → control, with the last hook wrapping the earlier renderers.
-- Each hook may replace drawing, but must keep its own stack pushes balanced and clip custom geometry to Visual.clip.
local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local geometry = require './geometry'
local theme = require './theme'
local textFieldGeometry = require './text-field-geometry'
local passState = require '@lunette-plugins/pass-state'
local depth = require './depth'
local measurement = require './measurement-cache'
local rounded = require '@lunette-plugins/theme/rounded-geometry'
local drawing = require '@lunette-plugins/theme/drawing'
export type Shape = {
  read bounds: ui.Bounds,
  read profile: rounded.Profile,
  read border: boolean?,
  read faceClip: ui.Bounds?,
}
export type Cache = { labels: measurement.Cache, fields: measurement.Cache, faces: drawing.Cache }
local draw = {}
function draw.newCache(): Cache
  return { labels = measurement.new(), fields = measurement.new(), faces = drawing.newCache() }
end
function draw.clearCache(cache: Cache): ()
  measurement.clear(cache.labels)
  measurement.clear(cache.fields)
  drawing.clear(cache.faces)
end

type TextEntry = {
  read value: string,
  read scale: number,
  read width: number,
  read shown: string?,
  read overflow: boolean,
}

local snapshot: (ui.Visual) -> ui.Visual
local protected: (Pass, Font, () -> ()) -> ()
local renderDefault: (Pass, ui.Visual, Cache?, Shape?) -> ()
local rectangle: (Pass, ui.Bounds, ui.Bounds) -> ()
local roundedBorder: (Pass, Cache, ui.Bounds, rounded.Profile, number, ui.Bounds) -> ()
local text: (Pass, Font, string, ui.Bounds, ui.Bounds, number, Cache?) -> boolean
local fittedText: (Font, string, number, number, number, Cache?) -> TextEntry
local renderTextField: (Pass, Font, ui.Visual, ui.Bounds, Cache?) -> boolean
local renderItems: (Pass, Font, ui.Visual, ui.Bounds, Cache?) -> boolean
local inset: (ui.Bounds, number) -> ui.Bounds
local sameBounds: (ui.Bounds, ui.Bounds) -> boolean
local validateGeometry: (ui.Visual, ui.Visual) -> ()
local setColor: (Pass, ui.Color) -> ()
local singleLine: (string) -> string

function draw.render(
  pass: Pass,
  visual: ui.Visual,
  hooks: { read [number]: ui.DrawHook }?,
  cache: Cache?,
  shape: Shape?
): ()
  local declared = snapshot(visual)
  local owned = if cache then nil else draw.newCache()
  local currentCache: Cache = assert(cache or owned)
  currentCache.faces.limit = math.max(96, (#declared.items + 1) * 3)
  local renderer: ui.Renderer = function(target: Pass, value: ui.Visual): ()
    validateGeometry(value, declared)
    local immutable = snapshot(value)
    protected(target, immutable.theme.font, function()
      renderDefault(target, immutable, currentCache, shape)
    end)
  end
  for _, hook in hooks or {} do
    local base = renderer
    renderer = function(target: Pass, value: ui.Visual): ()
      validateGeometry(value, declared)
      local immutable = snapshot(value)
      protected(target, immutable.theme.font, function()
        hook(target, immutable, base)
      end)
    end
  end
  local ok, failure = pcall(function(): boolean
    renderer(pass, declared)
    return true
  end)
  local cleaned, cleanupFailure = true, nil
  if owned then
    cleaned, cleanupFailure = pcall(function(): boolean
      draw.clearCache(owned)
      return true
    end)
  end
  if not ok then
    error(failure, 0)
  elseif not cleaned then
    error(cleanupFailure, 0)
  end
end

snapshot = function(value: ui.Visual): ui.Visual
  local items: { ui.ItemDescription } = {}
  for _, item in value.items do
    local route = if item.route then geometry.validatePolyline(item.route) else nil
    table.insert(
      items,
      table.freeze {
        id = item.id,
        label = item.label,
        enabled = item.enabled,
        selected = item.selected,
        bounds = if item.bounds then geometry.validateBounds(item.bounds) else nil,
        route = route,
      }
    )
  end
  return table.freeze {
    id = value.id,
    kind = value.kind,
    label = value.label,
    bounds = geometry.validateBounds(value.bounds),
    clip = geometry.validateBounds(value.clip),
    theme = theme.validate(value.theme),
    enabled = value.enabled,
    hovered = value.hovered,
    pressed = value.pressed,
    focused = value.focused,
    value = value.value,
    caret = value.caret,
    anchor = value.anchor,
    error = value.error,
    opened = value.opened,
    overflow = value.overflow,
    items = table.freeze(items),
  }
end

protected = function(pass: Pass, font: Font, render: () -> ()): ()
  passState.withRestore(pass, function()
    pass:setShader()
    pass:setMaterial(nil)
    pass:setFont(font)
    pass:setCullMode 'none'
    pass:setDepthTest 'gequal'
    pass:setDepthWrite(false)
    render()
  end)
end

renderDefault = function(pass: Pass, visual: ui.Visual, cache: Cache?, shape: Shape?): ()
  local clip = geometry.intersect(visual.bounds, visual.clip)
  if not clip then
    return
  end
  local font, style = visual.theme.font, visual.theme
  geometry.positive(font:getHeight(), 'font height')
  pass:setShader()
  pass:setMaterial(nil)
  pass:setFont(font)
  pass:setCullMode 'none'
  pass:setDepthTest 'gequal'
  local bounds = if shape then shape.bounds else visual.bounds
  local profile = if shape
    then shape.profile
    else rounded.uniform(if visual.kind == 'panel' then style.panelRadius else style.controlRadius)
  local faceColor = if visual.kind == 'panel'
    then style.background
    elseif not visual.enabled then style.disabled
    elseif visual.pressed then style.pressed
    elseif visual.hovered then style.hovered
    else style.control
  pass:setDepthWrite(visual.kind == 'panel' and faceColor[4] == 1)
  setColor(pass, faceColor)
  drawing.face(pass, (cache :: Cache).faces, bounds, profile, if shape and shape.faceClip then shape.faceClip else clip)
  if visual.kind == 'panel' then
    if not shape or shape.border ~= false then
      setColor(pass, style.border)
      pass:setDepthWrite(style.border[4] == 1)
      roundedBorder(pass, cache :: Cache, bounds, profile, style.borderWidth, clip)
    end
    return
  end
  -- Controls and glyphs retain painter order in front of the opaque backing.
  pass:setDepthWrite(false)
  pass:translate(0, 0, depth.layer)
  local textClip = geometry.intersect(clip, rounded.safeClip(bounds, profile))
  if not textClip then
    return
  end
  local content = inset(visual.bounds, style.padding)
  local overflow = visual.overflow == true
  if visual.kind == 'text-field' then
    overflow = renderTextField(pass, font, visual, textClip, cache) or overflow
  elseif visual.kind == 'choice' then
    local header: ui.Bounds = {
      x = visual.bounds.x,
      y = visual.bounds.y,
      width = visual.bounds.width,
      height = math.min(visual.bounds.height, style.rowHeight),
    }
    setColor(pass, if visual.enabled then style.foreground else style.border)
    overflow = text(
      pass,
      font,
      visual.value or visual.label,
      inset(header, style.padding),
      textClip,
      style.fontSize,
      cache
    ) or overflow
    if visual.opened then
      overflow = renderItems(pass, font, visual, clip, cache) or overflow
    end
  elseif visual.kind == 'list' or visual.kind == 'region' then
    overflow = renderItems(pass, font, visual, clip, cache) or overflow
  else
    setColor(pass, if visual.enabled then style.foreground else style.border)
    overflow = text(pass, font, visual.label, content, textClip, style.fontSize, cache) or overflow
  end
  if visual.error and visual.error ~= '' then
    setColor(pass, style.error)
    local height = math.min(style.fontSize, content.height)
    local message = { x = content.x, y = content.y + content.height - height, width = content.width, height = height }
    text(pass, font, visual.error, message, textClip, style.fontSize, cache)
  end
  setColor(pass, if visual.error then style.error elseif visual.focused then style.focus else style.border)
  if not shape or shape.border ~= false then
    roundedBorder(
      pass,
      cache :: Cache,
      bounds,
      profile,
      if visual.focused or visual.error then math.max(2, style.borderWidth) else style.borderWidth,
      clip
    )
  end
  if overflow then
    setColor(pass, if visual.error then style.error else style.focus)
    local thickness = math.min(3, visual.bounds.height)
    rectangle(pass, {
      x = visual.bounds.x,
      y = visual.bounds.y + visual.bounds.height - thickness,
      width = visual.bounds.width,
      height = thickness,
    }, textClip)
  end
end

rectangle = function(pass: Pass, bounds: ui.Bounds, clip: ui.Bounds): ()
  local visible = geometry.intersect(bounds, clip)
  if visible then
    pass:plane(visible.x + visible.width / 2, visible.y + visible.height / 2, 0, visible.width, visible.height)
  end
end

roundedBorder = function(
  pass: Pass,
  cache: Cache,
  bounds: ui.Bounds,
  profile: rounded.Profile,
  width: number,
  clip: ui.Bounds
): ()
  drawing.insideBorder(pass, cache.faces, bounds, profile, width, clip)
end

text = function(
  pass: Pass,
  font: Font,
  value: string,
  bounds: ui.Bounds,
  clip: ui.Bounds,
  size: number,
  cache: Cache?
): boolean
  if value == '' then
    return false
  end
  local visible = geometry.intersect(bounds, clip)
  if not visible then
    return true
  end
  local height = font:getHeight()
  local scale = math.min(size, visible.height) / height
  local fitted = fittedText(font, value, scale, visible.width, height, cache)
  if fitted.shown then
    -- Glyphs are y-up, while logical panel coordinates are y-down.
    pass:text(fitted.shown, visible.x, visible.y, depth.layer, scale, math.pi, 1, 0, 0, 0, 'left', 'top')
  end
  return fitted.overflow
end

fittedText = function(
  font: Font,
  value: string,
  scale: number,
  width: number,
  _height: number,
  cache: Cache?
): TextEntry
  local entries = measurement.entries(if cache then cache.labels else nil, font)
  for index, raw in entries or {} do
    local entry = raw :: TextEntry
    if entry.value == value and entry.scale == scale and entry.width == width then
      table.remove(entries :: { unknown }, index)
      table.insert(entries :: { unknown }, entry)
      return entry
    end
  end
  local line = singleLine(value)
  local shown: string? = line
  local overflow = line ~= value or font:getWidth(line) * scale > width
  if overflow then
    local suffix = '…'
    if font:getWidth(suffix) * scale > width then
      shown = nil
    else
      local boundaries = lunette.textBoundaries(line)
      local prefix = ''
      for index = 2, #boundaries do
        local candidate = line:sub(1, boundaries[index] - 1)
        if font:getWidth(candidate .. suffix) * scale <= width then
          prefix = candidate
        end
      end
      shown = prefix .. suffix
    end
  end
  local result: TextEntry = { value = value, scale = scale, width = width, shown = shown, overflow = overflow }
  measurement.store(entries, result)
  return result
end

renderTextField = function(pass: Pass, font: Font, visual: ui.Visual, clip: ui.Bounds, cache: Cache?): boolean
  local style, value = visual.theme, visual.value or ''
  local layout = textFieldGeometry.layout(
    value,
    visual.caret or 1,
    visual.anchor or visual.caret or 1,
    visual.bounds,
    clip,
    style,
    font,
    if cache then cache.fields else nil,
    clip
  )
  if not layout then
    return value ~= ''
  end
  if value == '' then
    setColor(pass, style.border)
    text(pass, font, visual.label, layout.visible, layout.visible, style.fontSize, cache)
  end
  local selection = layout.selectionBounds
  if selection then
    setColor(pass, style.selection)
    rectangle(pass, selection, layout.visible)
  end
  setColor(pass, if visual.enabled then style.foreground else style.border)
  if layout.text ~= '' then
    pass:text(
      layout.text,
      layout.origin.x,
      layout.origin.y,
      depth.layer,
      layout.scale,
      math.pi,
      1,
      0,
      0,
      0,
      'left',
      'top'
    )
  end
  if visual.focused then
    setColor(pass, style.focus)
    rectangle(pass, layout.caretBounds, layout.visible)
  end
  return layout.overflow
end

renderItems = function(pass: Pass, font: Font, visual: ui.Visual, clip: ui.Bounds, cache: Cache?): boolean
  local style, overflow = visual.theme, false
  for _, item in visual.items do
    if item.bounds then
      local visible = geometry.intersect(item.bounds, clip)
      if not visible then
        overflow = true
        continue
      end
      overflow = not sameBounds(visible, item.bounds) or overflow
      setColor(
        pass,
        if not visual.enabled or not item.enabled
          then style.disabled
          elseif item.selected then style.selection
          else style.control
      )
      local profile = rounded.uniform(style.controlRadius)
      drawing.face(pass, (cache :: Cache).faces, item.bounds, profile, clip)
      local textClip = geometry.intersect(clip, rounded.safeClip(item.bounds, profile))
      if item.route then
        setColor(pass, if item.selected then style.focus else style.border)
        for _, segment in geometry.clipPolyline(item.route, clip) do
          pass:line(segment.from.x, segment.from.y, 0, segment.to.x, segment.to.y, 0)
        end
      end
      setColor(pass, if item.enabled and visual.enabled then style.foreground else style.border)
      if textClip then
        overflow = text(pass, font, item.label, inset(item.bounds, style.padding), textClip, style.fontSize, cache)
          or overflow
      else
        overflow = true
      end
      if item.selected then
        setColor(pass, style.focus)
        roundedBorder(pass, cache :: Cache, item.bounds, profile, math.max(2, style.borderWidth), clip)
      end
    end
  end
  return overflow
end

inset = function(bounds: ui.Bounds, padding: number): ui.Bounds
  local x, y = math.min(padding, bounds.width / 2), math.min(padding, bounds.height / 2)
  return { x = bounds.x + x, y = bounds.y + y, width = bounds.width - 2 * x, height = bounds.height - 2 * y }
end

sameBounds = function(a: ui.Bounds, b: ui.Bounds): boolean
  return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

validateGeometry = function(value: ui.Visual, declared: ui.Visual): ()
  assert(value.id == declared.id and value.kind == declared.kind, 'ui drawing: hook cannot replace visual identity')
  assert(
    sameBounds(value.bounds, declared.bounds) and sameBounds(value.clip, declared.clip),
    'ui drawing: hook cannot change geometry'
  )
  assert(#value.items == #declared.items, 'ui drawing: hook cannot change item geometry')
  for index, item in value.items do
    local original = declared.items[index]
    assert(item.id == original.id, 'ui drawing: hook cannot replace item identity')
    if item.bounds and original.bounds then
      assert(sameBounds(item.bounds, original.bounds), 'ui drawing: hook cannot change item geometry')
    else
      assert(item.bounds == original.bounds, 'ui drawing: hook cannot change item geometry')
    end
    if item.route and original.route then
      assert(#item.route == #original.route, 'ui drawing: hook cannot change route geometry')
      for pointIndex, point in item.route do
        local other = original.route[pointIndex]
        assert(point.x == other.x and point.y == other.y, 'ui drawing: hook cannot change route geometry')
      end
    else
      assert(item.route == original.route, 'ui drawing: hook cannot change route geometry')
    end
  end
end

setColor = function(pass: Pass, color: ui.Color): ()
  pass:setColor(color[1], color[2], color[3], color[4])
end

singleLine = function(value: string): string
  return (value:gsub('[\r\n]', ' '))
end

return draw
