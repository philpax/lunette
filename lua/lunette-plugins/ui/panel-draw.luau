-- Panel rendering draws the panel face and then each live control's logical visual in paint order.
local ui = require '@lunette-contracts/ui'
local records = require '@lunette-plugins/ui/panel-state'
local input = require '@lunette-plugins/ui/input'
local geometry = require '@lunette-plugins/ui/geometry'
local draw = require '@lunette-plugins/ui/draw'
local panelGeometry = require './panel-geometry'

local panelDraw = {}

local live: (records.Panel) -> boolean
local render: (records.Panel, Pass, ui.Visual, records.Control?) -> ()
local visual: (records.Panel, records.Control, ui.Bounds) -> ui.Visual

function panelDraw.render(state: records.Panel, pass: Pass): ()
  state.refresh()
  if not live(state) then
    return
  end
  local controls = input.ordered(state.controls)
  pass:push 'transform'
  local ok, failure = pcall(function(): ()
    pass:transform(state.pose)
    pass:translate(-state.width / 2, state.height / 2, draw.depth.surface)
    pass:scale(state.width / state.logicalWidth, -state.height / state.logicalHeight, 1)
    local clip: ui.Bounds = { x = 0, y = 0, width = state.logicalWidth, height = state.logicalHeight }
    render(state, pass, {
      id = state.name,
      kind = 'panel',
      label = '',
      bounds = clip,
      clip = clip,
      theme = state.theme,
      enabled = true,
      hovered = false,
      pressed = false,
      focused = false,
      items = {},
    }, nil)
    -- Sibling controls keep painter order; only nesting adds physical depth.
    pass:translate(0, 0, draw.depth.layer)
    for _, record in controls do
      if not live(state) then
        break
      end
      local bounds = input.bounds(state, record)
      if not record.dead and bounds then
        render(state, pass, record.widget.visual(table.freeze(visual(state, record, bounds))), record)
      end
    end
  end)
  -- A draw hook can end the panel or a control mid-frame; release what the rest of that frame cached.
  if state.dead then
    draw.clearCache(state.measurements)
  end
  for _, record in controls do
    if record.dead then
      draw.clearCache(record.measurements)
    end
  end
  if not ok then
    pcall(pass.pop, pass, 'transform')
    error(failure, 0)
  end
  pass:pop 'transform'
  panelGeometry.drawFrame(state, pass)
end

function panelDraw.clippedItems(state: records.Panel, record: records.Control): { read [number]: ui.ItemDescription }
  local visible = input.bounds(state, record)
  local result: { ui.ItemDescription } = {}
  if not visible then
    return table.freeze(result)
  end
  local described = record.widget.items(visible, record.theme)
  for index = 1, #described do
    local item = described[index]
    result[#result + 1] = table.freeze {
      id = item.id,
      label = item.label,
      enabled = item.enabled and record.enabled,
      selected = item.selected,
      bounds = item.bounds and geometry.intersect(item.bounds, visible),
      route = item.route,
    }
  end
  return table.freeze(result)
end

live = function(state: records.Panel): boolean
  return not state.dead and state.visible and state.context:active() and state.context:owns(state.owner)
end

render = function(state: records.Panel, pass: Pass, value: ui.Visual, record: records.Control?): ()
  local hooks: { ui.DrawHook } = {}
  if state.providerDraw then
    hooks[#hooks + 1] = state.providerDraw
  end
  if state.draw then
    hooks[#hooks + 1] = state.draw
  end
  if record and record.draw then
    hooks[#hooks + 1] = record.draw
  end
  local prepared = panelGeometry.prepare(state)
  local shape = if not record or state.contour
    then {
      bounds = prepared.bounds,
      profile = prepared.profile,
      border = not state.contour and not panelGeometry.joined(state),
      faceClip = if record and state.contour
        then geometry.intersect(record.bounds, panelGeometry.bounds(state))
        else nil,
    }
    else nil
  draw.render(pass, value, hooks, if record then record.measurements else state.measurements, shape)
end

visual = function(state: records.Panel, record: records.Control, bounds: ui.Bounds): ui.Visual
  local hovered, pressed = false, false
  for _, current in state.hovered do
    if current == record then
      hovered = true
    end
  end
  for _, buttons in state.captures do
    for _, capture in buttons do
      if capture.control == record then
        pressed = true
      end
    end
  end
  return {
    id = record.id,
    kind = record.kind,
    label = record.label,
    bounds = record.bounds,
    clip = bounds,
    theme = record.theme,
    enabled = record.enabled,
    hovered = hovered,
    pressed = pressed,
    focused = record.focused,
    items = panelDraw.clippedItems(state, record),
  }
end

return panelDraw
