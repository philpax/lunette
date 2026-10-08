-- Panel rendering snapshots logical visuals and stops continuations invalidated by draw callbacks.
local ui = require '@lunette-contracts/ui'
local records = require '@lunette-plugins/ui/panel-state'
local controlOrder = require '@lunette-plugins/ui/control-order'
local input = require '@lunette-plugins/ui/input'
local geometry = require '@lunette-plugins/ui/geometry'
local draw = require '@lunette-plugins/ui/draw'
local depth = require '@lunette-plugins/ui/depth'

local panelDraw = {}

local live: (records.Panel, records.Control?) -> boolean
local guarded: (ui.DrawHook, () -> boolean) -> ui.DrawHook
local render: (records.Panel, Pass, ui.Visual, records.Control?) -> ()
local visual: (records.Panel, records.Control, ui.Bounds) -> ui.Visual

function panelDraw.render(state: records.Panel, pass: Pass): ()
  if not live(state, nil) then
    return
  end
  local pushed = false
  local ok, failure = pcall(function(): ()
    pass:push 'transform'
    pushed = true
    pass:transform(state.pose)
    pass:translate(-state.width / 2, state.height / 2, depth.surface)
    pass:scale(state.width / state.logicalWidth, -state.height / state.logicalHeight, 1)
    local drawRevision = state.revision
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
    pass:translate(0, 0, depth.layer)
    for _, record in ipairs(controlOrder.ordered(state.controls)) do
      if not live(state, nil) or state.revision ~= drawRevision then
        break
      end
      local bounds = input.bounds(state, record)
      if not live(state, record) or not bounds then
        continue
      end
      local revision = state.revision
      local described = visual(state, record, bounds)
      if not live(state, record) or state.revision ~= revision then
        continue
      end
      local decorated = record.widget.visual(table.freeze(described))
      if live(state, record) and state.revision == revision then
        render(state, pass, decorated, record)
      end
    end
  end)
  if pushed then
    local restored, restoreFailure = pcall(pass.pop, pass, 'transform')
    if ok and not restored then
      ok, failure = false, restoreFailure
    end
  end
  if not ok then
    error(failure, 0)
  end
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

live = function(state: records.Panel, record: records.Control?): boolean
  return not state.dead
    and state.visible
    and state.context:active()
    and state.context:owns(state.owner)
    and (not record or (not record.dead and state.context:owns(record.owner)))
end

guarded = function(hook: ui.DrawHook, available: () -> boolean): ui.DrawHook
  return function(pass: Pass, value: ui.Visual, base: ui.Renderer): ()
    if not available() then
      return
    end
    hook(pass, value, function(target: Pass, visual: ui.Visual): ()
      if available() then
        base(target, visual)
      end
    end)
  end
end

render = function(state: records.Panel, pass: Pass, value: ui.Visual, record: records.Control?): ()
  local revision = state.revision
  local function available(): boolean
    return live(state, record) and state.revision == revision
  end
  local hooks: { ui.DrawHook } = {}
  if state.providerDraw then
    hooks[#hooks + 1] = guarded(state.providerDraw, available)
  end
  if state.draw then
    hooks[#hooks + 1] = guarded(state.draw, available)
  end
  if record and record.draw then
    hooks[#hooks + 1] = guarded(record.draw, available)
  end
  if available() then
    draw.render(pass, value, hooks)
  end
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
