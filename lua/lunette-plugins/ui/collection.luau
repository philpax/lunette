-- Choices and lists share immutable items, clipped row geometry, and pointer captures.
-- A choice adds a primary-release header that opens its options inside the declared bounds.
local ui = require '@lunette-contracts/ui'
local records = require './panel-state'
local geometry = require './geometry'
local validation = require './validation'
local vocabulary = require '@lunette-contracts/vocabulary'

local collection = {}

type Kind = 'choice' | 'list'
type Press = { read id: string?, read bounds: ui.Bounds }
type Layout = { read header: ui.Bounds, read viewport: ui.Bounds, read maximum: number, read canOpen: boolean }

local layout: (ui.Bounds, ui.Theme, number, Kind) -> Layout

-- Options arrive validated; the methods validate their own arguments.
function collection.widget(kind: Kind, options: ui.ListOptions, host: records.Host): records.Widget
  local entries = options.items
  local selected = options.selected
  local opened = false
  local offset = 0
  local inputClip: ui.Bounds? = nil
  local presses: { [vocabulary.Pointer]: Press } = {}
  local onChange = options.onChange

  local function current(bounds: ui.Bounds, theme: ui.Theme): Layout
    return layout(bounds, theme, #entries, kind)
  end

  local function effectiveOpen(shape: Layout): boolean
    return kind == 'choice' and opened and shape.canOpen
  end

  local function cancelPresses(): ()
    table.clear(presses)
    host.cancel 'control-removed'
  end

  local function describe(clip: ui.Bounds, theme: ui.Theme): { read [number]: ui.ItemDescription }
    local result: { ui.ItemDescription } = {}
    local shape = current(host.bounds(), theme)
    if kind == 'choice' and not effectiveOpen(shape) then
      return table.freeze(result)
    end
    local viewport = geometry.intersect(shape.viewport, clip)
    if not viewport then
      return table.freeze(result)
    end
    local scrollOffset = math.clamp(offset, 0, shape.maximum)
    local stride = theme.rowHeight + theme.spacing
    for index, item in entries do
      local row: ui.Bounds = {
        x = shape.viewport.x,
        y = shape.viewport.y + (index - 1) * stride - scrollOffset,
        width = shape.viewport.width,
        height = theme.rowHeight,
      }
      local visible = geometry.intersect(row, viewport)
      if visible then
        local description: ui.ItemDescription = table.freeze {
          id = item.id,
          label = item.label,
          enabled = item.enabled ~= false,
          selected = item.id == selected,
          bounds = visible,
        }
        table.insert(result, description)
      end
    end
    return table.freeze(result)
  end

  local function itemAt(event: vocabulary.PointerEvent, id: string?): ui.ItemDescription?
    if id == nil then
      return nil
    end
    for _, item in describe(inputClip or host.bounds(), host.theme()) do
      local bounds = item.bounds
      if item.id == id and item.enabled and bounds and geometry.contains(bounds, event.x, event.y) then
        return item
      end
    end
    return nil
  end

  local function setItems(items: { read [number]: ui.Item }): ()
    if not host.live() then
      return
    end
    entries = validation.items(items)
    if selected then
      local retained = false
      for _, item in entries do
        retained = retained or item.id == selected
      end
      if not retained then
        selected = nil
      end
    end
    local shape = current(host.bounds(), host.theme())
    offset = math.clamp(offset, 0, shape.maximum)
    opened = opened and shape.canOpen
    host.changed()
    cancelPresses()
  end

  local function setSelected(id: string?): ()
    if not host.live() then
      return
    end
    validation.selected(entries, id)
    if id ~= selected then
      selected = id
      host.changed()
    end
  end

  local function setOpen(value: boolean): ()
    if not host.live() then
      return
    end
    if type(value) ~= 'boolean' then
      error('ui ' .. kind .. ': open is a boolean', 2)
    end
    local shape = current(host.bounds(), host.theme())
    local replacement = value and shape.canOpen
    if opened == replacement then
      return
    end
    opened = replacement
    offset = math.clamp(offset, 0, shape.maximum)
    host.changed()
    cancelPresses()
  end

  -- Both method and pointer scrolling add logical pixels; the pointer provider applies tuning once.
  local function scroll(delta: number): ()
    if not host.live() then
      return
    end
    if type(delta) ~= 'number' or not (math.abs(delta) < math.huge) then
      error('ui ' .. kind .. ': scroll delta is a finite number of logical pixels', 2)
    end
    local shape = current(host.bounds(), host.theme())
    local replacement = math.clamp(math.clamp(offset, 0, shape.maximum) + delta, 0, shape.maximum)
    if replacement == offset then
      return
    end
    offset = replacement
    host.changed()
    cancelPresses()
  end

  local function activate(id: string): ()
    local selectionChanged = selected ~= id
    local closed = kind == 'choice' and opened
    selected = id
    if closed then
      opened = false
    end
    if selectionChanged or closed then
      host.changed()
    end
    if closed then
      cancelPresses()
    end
    local callback = onChange
    if not host.live() or not selectionChanged or not callback then
      return
    end
    host.callback('ui ' .. kind .. ' onChange', function(): ()
      callback(id)
    end)
  end

  local function pointer(event: vocabulary.PointerEvent, id: string?): ()
    if event.kind == 'cancel' then
      if event.button == 'left' then
        presses[event.pointer] = nil
      end
      return
    end
    if not host.live() then
      return
    end
    if event.kind == 'scroll' then
      local shape = current(host.bounds(), host.theme())
      if kind == 'list' or effectiveOpen(shape) then
        scroll(event.dy)
      end
      return
    end
    if event.kind ~= 'press' and event.kind ~= 'release' then
      return
    end
    if event.button ~= 'left' then
      return
    end
    local shape = current(host.bounds(), host.theme())
    if event.kind == 'press' then
      if not event.inside or presses[event.pointer] then
        return
      end
      local item = itemAt(event, id)
      if item and item.bounds then
        presses[event.pointer] = { id = item.id, bounds = item.bounds }
      elseif kind == 'choice' and id == nil then
        local target = if effectiveOpen(shape) then shape.header else host.bounds()
        local bounds = geometry.intersect(target, inputClip or host.bounds())
        if bounds and geometry.contains(bounds, event.x, event.y) then
          presses[event.pointer] = { bounds = bounds }
        end
      end
      return
    end
    local pressed = presses[event.pointer]
    presses[event.pointer] = nil
    if not pressed or not event.inside then
      return
    end
    if pressed.id then
      local item = itemAt(event, id)
      if item and item.id == pressed.id and item.bounds and geometry.sameBounds(pressed.bounds, item.bounds) then
        activate(item.id)
      end
    elseif kind == 'choice' and id == nil then
      local target = if effectiveOpen(shape) then shape.header else host.bounds()
      local bounds = geometry.intersect(target, inputClip or host.bounds())
      if bounds and geometry.sameBounds(pressed.bounds, bounds) and geometry.contains(bounds, event.x, event.y) then
        setOpen(not effectiveOpen(shape))
      end
    end
  end

  local function visual(base: ui.Visual): ui.Visual
    local shape = current(host.bounds(), base.theme)
    local value: string? = nil
    for _, item in entries do
      if item.id == selected then
        value = item.label
        break
      end
    end
    local result: ui.Visual = table.freeze {
      id = base.id,
      kind = base.kind,
      label = base.label,
      bounds = base.bounds,
      clip = base.clip,
      theme = base.theme,
      enabled = base.enabled,
      hovered = base.hovered,
      pressed = base.pressed,
      focused = base.focused,
      value = if kind == 'choice' then value else base.value,
      caret = base.caret,
      anchor = base.anchor,
      error = base.error,
      opened = if kind == 'choice' then effectiveOpen(shape) else nil,
      overflow = shape.maximum > 0 and (kind == 'list' or effectiveOpen(shape)),
      items = describe(base.clip, base.theme),
    }
    return result
  end

  local methods: { [string]: unknown } = {
    setItems = function(_self: ui.List, items: { read [number]: ui.Item }): ()
      setItems(items)
    end,
    setSelected = function(_self: ui.List, id: string?): ()
      setSelected(id)
    end,
    selected = function(_self: ui.List): string?
      return selected
    end,
    scroll = function(_self: ui.List, pixels: number): ()
      scroll(pixels)
    end,
  }
  if kind == 'choice' then
    methods.setOpen = function(_self: ui.Choice, value: boolean): ()
      setOpen(value)
    end
  end
  local widget: records.Widget = {
    wantsKeyboard = false,
    methods = table.freeze(methods),
    pointer = pointer,
    items = function(clip: ui.Bounds, theme: ui.Theme): { read [number]: ui.ItemDescription }
      inputClip = table.freeze(table.clone(clip))
      return describe(clip, theme)
    end,
    visual = visual,
  }
  return table.freeze(widget)
end

layout = function(bounds: ui.Bounds, theme: ui.Theme, count: number, kind: Kind): Layout
  local inset = theme.padding
  local top = if kind == 'choice' then theme.rowHeight + theme.spacing else 0
  local header: ui.Bounds = table.freeze {
    x = bounds.x,
    y = bounds.y,
    width = bounds.width,
    height = math.min(bounds.height, theme.rowHeight),
  }
  local viewport: ui.Bounds = table.freeze {
    x = bounds.x + inset,
    y = bounds.y + top + inset,
    width = math.max(0, bounds.width - inset * 2),
    height = math.max(0, bounds.height - top - inset * 2),
  }
  local content = if count == 0 then 0 else count * theme.rowHeight + (count - 1) * theme.spacing
  return {
    header = header,
    viewport = viewport,
    maximum = math.max(0, content - viewport.height),
    canOpen = count > 0 and viewport.width > 0 and viewport.height >= theme.rowHeight,
  }
end

return collection
