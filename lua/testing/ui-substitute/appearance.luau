-- Resolves visual themes and isolates public renderer hooks from caller pass state.

local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local protected = require '@lunette-plugins/protected'
local geometry = require './geometry'
local rounded = require '@lunette-plugins/theme/rounded-geometry'
local drawing = require '@lunette-plugins/theme/drawing'
local textLayout = require './text-layout'

local appearance = {}
local defaultRenderer
local visualSnapshot, validateGeometry, sameBounds

appearance.defaultTheme = {
  background = { 0.08, 0.08, 0.08, 1 },
  foreground = { 1, 1, 1, 1 },
  control = { 0.2, 0.2, 0.2, 1 },
  hovered = { 0.3, 0.3, 0.3, 1 },
  pressed = { 0.4, 0.4, 0.4, 1 },
  disabled = { 0.1, 0.1, 0.1, 1 },
  focus = { 0.2, 0.5, 1, 1 },
  selection = { 0.3, 0.4, 0.7, 1 },
  error = { 1, 0.2, 0.2, 1 },
  border = { 0.5, 0.5, 0.5, 1 },
  fontSize = 16,
  panelRadius = 0,
  controlRadius = 0,
  padding = 4,
  spacing = 2,
  borderWidth = 1,
  rowHeight = 24,
  hapticStrength = 0.1,
  hapticDuration = 0.01,
}
for _, value in appearance.defaultTheme do
  if type(value) == 'table' then
    table.freeze(value)
  end
end
table.freeze(appearance.defaultTheme)

function appearance.copyOverrides(overrides)
  if overrides == nil then
    return nil
  end
  assert(type(overrides) == 'table' and getmetatable(overrides) == nil, 'ui substitute: theme is a plain table')
  local result = {}
  for key, value in overrides do
    if key == 'font' then
      assert(type(value) == 'table' and getmetatable(value) == nil, 'ui substitute: font is a plain specification')
      local allowed = if value.kind == 'default'
        then { kind = true }
        else { kind = true, file = true, size = true, spread = true }
      for field in value do
        assert(allowed[field], 'ui substitute: unknown font field ' .. tostring(field))
      end
      assert(value.kind == 'default' or value.kind == 'file', 'ui substitute: font kind is default or file')
      if value.kind == 'file' then
        assert(type(value.file) == 'string' and value.file ~= '', 'ui substitute: font file is nonempty')
        for _, field in { 'size', 'spread' } do
          assert(geometry.finite(value[field]) and value[field] > 0, 'ui substitute: font size and spread are positive')
        end
      end
      result[key] = table.freeze(table.clone(value))
    else
      local default = appearance.defaultTheme[key]
      assert(default ~= nil, 'ui substitute: unknown theme field ' .. tostring(key))
      if type(default) == 'table' then
        assert(type(value) == 'table' and getmetatable(value) == nil, 'ui substitute: color is a plain array')
        local count = 0
        for channel, number in value do
          assert(
            type(channel) == 'number' and channel % 1 == 0 and channel >= 1 and channel <= 4,
            'ui substitute: color has four channels'
          )
          assert(geometry.finite(number) and number >= 0 and number <= 1, 'ui substitute: color channels are in [0, 1]')
          count += 1
        end
        assert(count == 4, 'ui substitute: color has four channels')
        result[key] = table.freeze(table.clone(value))
      else
        assert(geometry.finite(value) and value >= 0, 'ui substitute: theme measurements are finite and nonnegative')
        assert(
          (key ~= 'rowHeight' and key ~= 'fontSize') or value > 0,
          'ui substitute: font and row sizes are positive'
        )
        result[key] = value
      end
    end
  end
  return table.freeze(result)
end

function appearance.theme(base, overrides)
  local result = table.clone(base)
  for key, value in overrides or {} do
    result[key] = if key == 'font'
      then value
      elseif type(value) == 'table' then table.freeze(table.clone(value))
      else value
  end
  return table.freeze(result)
end

function appearance.global(snapshot)
  local global = snapshot.theme
  local result = table.clone(appearance.defaultTheme)
  for key, value in result do
    if type(value) == 'table' then
      result[key] = global.colors[key]
    end
  end
  result.font = global.typography.font
  result.fontSize = global.typography.bodySize
  result.panelRadius, result.controlRadius = global.radii.uiPanel, global.radii.uiControl
  for _, key in { 'padding', 'spacing', 'borderWidth', 'rowHeight' } do
    result[key] = global.metrics[key]
  end
  return table.freeze(result)
end

function appearance.resolve(record, base, overrides)
  if not record.provider.context:active() or not record.owner:active() then
    return false
  end
  local nextTheme = appearance.theme(base, overrides)
  local previous = record.resolved
  local spec = nextTheme.font
  local lease = record.lease
  if
    not lease
    or lease.spec.kind ~= spec.kind
    or (
      spec.kind == 'file'
      and (lease.spec.file ~= spec.file or lease.spec.size ~= spec.size or lease.spec.spread ~= spec.spread)
    )
  then
    local nextLease, nextEffect = record.provider.context:resource(record.owner, function()
      local acquired = record.provider.theme:acquireFont(record.provider.context, spec)
      return acquired, function()
        acquired:dispose()
      end
    end)
    local previousEffect = record.fontEffect
    record.lease, record.fontEffect = nextLease, nextEffect
    if previousEffect then
      previousEffect:dispose()
    end
  end
  record.layer = nextTheme
  local resolved = table.clone(nextTheme)
  resolved.font = record.lease.font
  record.resolved = table.freeze(resolved)
  return previous ~= nil
    and (
      previous.font ~= resolved.font
      or previous.fontSize ~= resolved.fontSize
      or previous.padding ~= resolved.padding
      or previous.spacing ~= resolved.spacing
      or previous.rowHeight ~= resolved.rowHeight
      or previous.borderWidth ~= resolved.borderWidth
      or previous.panelRadius ~= resolved.panelRadius
      or previous.controlRadius ~= resolved.controlRadius
    )
end

function appearance.release(record)
  local effect = record.fontEffect
  record.lease, record.fontEffect = nil, nil
  local released, failure = pcall(function()
    if effect then
      effect:dispose()
    end
  end)
  local cleared, cleanup = pcall(function()
    if record.meshes then
      drawing.clear(record.meshes)
    end
  end)
  if not released then
    error(tostring(failure) .. (if cleared then '' else '; ' .. tostring(cleanup)), 0)
  end
  if not cleared then
    error(cleanup, 0)
  end
end

function appearance.callback(control, label, run, terminal)
  local allowed = if terminal then control.owner:active() and control.panel.owner:active() else control.live()
  return allowed
    and protected.call('ui substitute ' .. plugin.ownerLabel(control.owner) .. ' ' .. control.id .. ' ' .. label, run)
end

function appearance.focusCallback(control, label, run)
  local ok, result = pcall(run)
  if not ok then
    error(
      'ui substitute '
        .. plugin.ownerLabel(control.owner)
        .. ' '
        .. control.id
        .. ' '
        .. label
        .. ': '
        .. tostring(result),
      0
    )
  end
  return result
end

function appearance.paint(owner, pass, visual, hooks, cache, shape, current)
  local declared = visualSnapshot(visual)
  local function guarded(render)
    return function(target, value)
      if current and not current() then
        return
      end
      validateGeometry(value, declared)
      local immutable = visualSnapshot(value)
      appearance.renderProtected(target, function()
        target:setShader()
        target:setMaterial(nil)
        target:setFont(immutable.theme.font)
        target:setCullMode 'none'
        target:setDepthTest 'gequal'
        target:setDepthWrite(false)
        render(target, immutable)
      end)
    end
  end
  local renderer = guarded(function(target, value)
    defaultRenderer(target, value, cache, shape)
  end)
  for _, hook in hooks or {} do
    local base = renderer
    renderer = guarded(function(target, value)
      hook(target, value, base)
    end)
  end
  protected.call('ui substitute ' .. plugin.ownerLabel(owner) .. ' draw ' .. declared.id, function()
    renderer(pass, declared)
  end)
end

function appearance.renderProtected(pass, render)
  local state, transform = false, false
  local ok, message = pcall(function()
    pass:push 'state'
    state = true
    pass:push 'transform'
    transform = true
    render()
  end)
  -- Attempt both restorations, retaining the rendering error when cleanup also raises.
  if transform then
    local restored, problem = pcall(pass.pop, pass, 'transform')
    if ok and not restored then
      ok, message = false, problem
    end
  end
  if state then
    local restored, problem = pcall(pass.pop, pass, 'state')
    if ok and not restored then
      ok, message = false, problem
    end
  end
  if not ok then
    error(message, 0)
  end
end

function appearance.snapshotItems(values)
  local result = {}
  for _, item in values do
    local route
    if item.route then
      route = {}
      for index, point in item.route do
        assert(geometry.finite(point.x) and geometry.finite(point.y), 'ui substitute: route points are finite')
        route[index] = table.freeze { x = point.x, y = point.y }
      end
      table.freeze(route)
    end
    result[#result + 1] = table.freeze {
      id = item.id,
      label = item.label,
      enabled = item.enabled,
      selected = item.selected,
      bounds = if item.bounds then geometry.bounds(item.bounds) else nil,
      route = route,
    }
  end
  return table.freeze(result)
end

visualSnapshot = function(value)
  return table.freeze {
    id = value.id,
    kind = value.kind,
    label = value.label,
    bounds = geometry.bounds(value.bounds),
    clip = geometry.bounds(value.clip),
    theme = appearance.theme(appearance.defaultTheme, value.theme),
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
    items = appearance.snapshotItems(value.items),
  }
end

sameBounds = function(a, b)
  return a and b and a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

validateGeometry = function(value, declared)
  assert(value.id == declared.id and value.kind == declared.kind, 'ui substitute: hook cannot replace visual identity')
  assert(
    sameBounds(value.bounds, declared.bounds) and sameBounds(value.clip, declared.clip),
    'ui substitute: hook cannot change geometry'
  )
  assert(#value.items == #declared.items, 'ui substitute: hook cannot change item geometry')
  for index, item in value.items do
    local original = declared.items[index]
    assert(item.id == original.id, 'ui substitute: hook cannot replace item identity')
    assert(
      (item.bounds == nil and original.bounds == nil) or sameBounds(item.bounds, original.bounds),
      'ui substitute: hook cannot change item geometry'
    )
    if item.route and original.route then
      assert(#item.route == #original.route, 'ui substitute: hook cannot change route geometry')
      for pointIndex, point in item.route do
        local other = original.route[pointIndex]
        assert(point.x == other.x and point.y == other.y, 'ui substitute: hook cannot change route geometry')
      end
    else
      assert(item.route == original.route, 'ui substitute: hook cannot change route geometry')
    end
  end
end

-- Recorder geometry establishes clipping and ownership, not native rasterization acceptance.
defaultRenderer = function(pass: Pass, visual: ui.Visual, cache, shape)
  local clip = geometry.intersect(visual.bounds, visual.clip)
  if not clip then
    return
  end
  local style = visual.theme
  local bounds = if shape then shape.bounds else visual.bounds
  local profile = if shape
    then shape.profile
    else rounded.uniform(if visual.kind == 'panel' then style.panelRadius else style.controlRadius)
  local color = if visual.kind == 'panel'
    then style.background
    elseif not visual.enabled then style.disabled
    elseif visual.pressed then style.pressed
    elseif visual.hovered then style.hovered
    else style.control
  pass:setColor(table.unpack(color))
  pass:setDepthWrite(visual.kind == 'panel' and color[4] == 1)
  drawing.face(pass, cache, bounds, profile, clip)
  local thickness = math.min(style.borderWidth, bounds.width / 2, bounds.height / 2)
  if thickness > 0 and (not shape or shape.border ~= false) then
    pass:setColor(table.unpack(style.border))
    pass:setDepthWrite(visual.kind == 'panel' and style.border[4] == 1)
    drawing.insideBorder(pass, cache, bounds, profile, thickness, clip)
  end
  if visual.kind == 'panel' then
    return
  end
  pass:setDepthWrite(false)
  local faceClip = rounded.safeClip(bounds, profile)
  local box = textLayout.box(visual.bounds, clip, style, faceClip)
  if visual.kind == 'text-field' then
    local field = textLayout.field(
      visual.value or '',
      visual.caret or 1,
      visual.anchor or visual.caret or 1,
      visual.bounds,
      clip,
      style,
      style.font,
      faceClip
    )
    if not field then
      return
    end
    local function rectangle(bounds, color)
      local visible = geometry.intersect(bounds, field.box)
      if visible then
        pass:setColor(table.unpack(color))
        pass:plane(visible.x + visible.width / 2, visible.y + visible.height / 2, 0.001, visible.width, visible.height)
      end
    end
    if field.selection then
      rectangle(field.selection, style.selection)
    end
    if field.text ~= '' then
      pass:setFont(style.font)
      pass:setColor(table.unpack(if visual.enabled then style.foreground else style.border))
      pass:text(field.text, field.box.x, field.box.y, 0.001, field.scale, math.pi, 1, 0, 0, 0, 'left', 'top')
    end
    if visual.focused then
      rectangle(field.caret, style.focus)
    end
    if visual.value ~= '' then
      return
    end
  end
  if not box then
    return
  end
  local text = if visual.kind == 'text-field' and visual.value == '' then visual.label else visual.value or visual.label
  local size = math.min(style.fontSize, box.height) / style.font:getHeight()
  if size > 0 and text ~= '' then
    while text ~= '' and style.font:getWidth(text) * size > box.width do
      local last = utf8.offset(text, -1)
      text = text:sub(1, last - 1)
    end
    if text ~= '' then
      pass:setFont(style.font)
      pass:setColor(table.unpack(style.foreground))
      pass:text(text, lovr.math.newMat4():translate(box.x, box.y, 0.001):scale(size), 0, 'left', 'bottom')
    end
  end
end

return appearance
