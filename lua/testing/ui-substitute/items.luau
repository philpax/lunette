-- Stable item identities share clipped descriptions and bounded logical-pixel scrolling.

local ui = require '@lunette-contracts/ui'
local geometry = require './geometry'

local items = {}

function items.copy(values, region)
  local result, ids = {}, {}
  for _, item in values do
    assert(type(item.id) == 'string' and item.id ~= '' and not ids[item.id], 'ui substitute: item ids are unique')
    ids[item.id] = true
    local copy = table.clone(item)
    assert(region or type(copy.label) == 'string', 'ui substitute: an item needs a label')
    if region then
      copy.bounds = geometry.bounds(item.bounds)
      if item.route then
        copy.route = {}
        for _, point in item.route do
          assert(geometry.finite(point.x) and geometry.finite(point.y), 'ui substitute: route points are finite')
          copy.route[#copy.route + 1] = table.freeze { x = point.x, y = point.y }
        end
        table.freeze(copy.route)
      end
    end
    result[#result + 1] = table.freeze(copy)
  end
  return table.freeze(result)
end

function items.rows(control)
  if control.kind == 'choice' and not control.opened then
    return {}
  end
  local result, box, style = {}, control.bounds, control.theme()
  local clip = geometry.intersect(box, control.panel.clip())
  if control.kind == 'region' then
    for _, item in control.items do
      local hit = geometry.intersect(item.bounds, clip)
      if hit then
        result[#result + 1] = {
          id = item.id,
          label = item.label or '',
          enabled = control.enabled,
          selected = false,
          bounds = hit,
          route = item.route,
        }
      end
    end
    return result
  end
  local header = if control.kind == 'choice' then style.rowHeight + style.spacing else 0
  local viewport = {
    x = box.x + style.padding,
    y = box.y + style.padding + header,
    width = math.max(0, box.width - 2 * style.padding),
    height = math.max(0, box.height - 2 * style.padding - header),
  }
  clip = geometry.intersect(viewport, clip)
  for index, item in control.items do
    local hit = geometry.intersect({
      x = viewport.x,
      y = viewport.y + (index - 1) * (style.rowHeight + style.spacing) - control.offset,
      width = viewport.width,
      height = style.rowHeight,
    }, clip)
    if hit then
      result[#result + 1] = {
        id = item.id,
        label = item.label,
        enabled = control.enabled and item.enabled ~= false,
        selected = item.id == control.chosen,
        bounds = hit,
      }
    end
  end
  return result
end

function items.scroll(control, delta)
  assert(geometry.finite(delta), 'ui substitute: scroll delta is finite')
  local style, box = control.theme(), control.bounds
  local header = if control.kind == 'choice' then style.rowHeight + style.spacing else 0
  local height = math.max(0, box.height - 2 * style.padding - header)
  local content = math.max(0, #control.items * (style.rowHeight + style.spacing) - style.spacing)
  control.offset = math.clamp(control.offset + delta, 0, math.max(0, content - height))
end

function items.selected(control, id)
  if id == nil then
    return nil
  end
  for _, item in control.items do
    if item.id == id and item.enabled ~= false then
      return id
    end
  end
  error('ui substitute: selected item is absent or disabled', 2)
end

function items.install(control)
  local handle, options, kind = control.handle, control.options, control.kind
  control.items = items.copy(options.items, false)
  control.chosen = items.selected(control, options.selected)
  local function setItems(values)
    if not control.live() then
      return
    end
    local replacement = items.copy(values, false)
    control.changed()
    control.items = replacement
    if #replacement == 0 then
      control.opened = false
    end
    local retained = false
    for _, item in replacement do
      if item.id == control.chosen and item.enabled ~= false then
        retained = true
      end
    end
    if not retained then
      control.chosen = nil
    end
    items.scroll(control, 0)
  end
  local function setSelected(id)
    if control.live() then
      control.chosen = items.selected(control, id)
    end
  end
  if kind == 'choice' then
    function handle.setItems(_: ui.Choice, values: { ui.Item })
      setItems(values)
    end
    function handle.setSelected(_: ui.Choice, id: string?)
      setSelected(id)
    end
    function handle.selected(_: ui.Choice): string?
      return control.chosen
    end
    function handle.setOpen(_: ui.Choice, value: boolean)
      if not control.live() then
        return
      end
      control.changed()
      local style = control.theme()
      control.opened = value
        and #control.items > 0
        and control.bounds.height >= 2 * style.padding + 2 * style.rowHeight + style.spacing
    end
    function handle.scroll(_: ui.Choice, delta: number)
      if control.live() then
        control.changed()
        items.scroll(control, delta)
      end
    end
  else
    function handle.setItems(_: ui.List, values: { ui.Item })
      setItems(values)
    end
    function handle.setSelected(_: ui.List, id: string?)
      setSelected(id)
    end
    function handle.selected(_: ui.List): string?
      return control.chosen
    end
    function handle.scroll(_: ui.List, delta: number)
      if control.live() then
        control.changed()
        items.scroll(control, delta)
      end
    end
  end
end

return items
