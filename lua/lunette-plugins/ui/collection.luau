-- Choice and list controllers share immutable items, clipped row geometry, and pointer captures.
local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'
local control = require './control'

local collection = {}

export type Controller = {
  read setItems: ({ read [number]: ui.Item }) -> (),
  read setSelected: (string?) -> (),
  read selected: () -> string?,
  read setOpen: (boolean) -> (),
  read scroll: (number) -> (),
  read pointer: (surface.PointerEvent, string?) -> (),
  read items: (ui.Bounds, ui.Theme) -> { read [number]: ui.ItemDescription },
  read visual: (ui.Visual) -> ui.Visual,
}

type Items = { read [number]: ui.Item }
type Kind = 'choice' | 'list'
type Press = { read id: string?, read bounds: ui.Bounds }
type Layout = { read header: ui.Bounds, read viewport: ui.Bounds, read maximum: number, read canOpen: boolean }

local snapshot: (Kind, Items) -> Items
local selectedId: (Kind, Items, string?) -> string?
local layout: (ui.Bounds, ui.Theme, number, Kind) -> Layout
local intersect: (ui.Bounds, ui.Bounds) -> ui.Bounds?
local contains: (ui.Bounds, number?, number?) -> boolean
local sameBounds: (ui.Bounds, ui.Bounds) -> boolean
local finite: (unknown) -> boolean

function collection.new(kind: Kind, options: ui.ListOptions, host: control.Host): Controller
  local entries = snapshot(kind, options.items)
  local selected = selectedId(kind, entries, options.selected)
  local opened = false
  local offset = 0
  local revision = 0
  local inputClip: ui.Bounds? = nil
  local presses: { [surface.Pointer]: Press } = {}
  local onChange = options.onChange
  if onChange ~= nil and type(onChange) ~= 'function' then
    error('ui ' .. kind .. ': onChange is a function', 2)
  end

  local function current(bounds: ui.Bounds, theme: ui.Theme): Layout
    return layout(bounds, theme, #entries, kind)
  end

  local function effectiveOpen(geometry: Layout): boolean
    return kind == 'choice' and opened and geometry.canOpen
  end

  local function changed(): ()
    revision += 1
    host.changed()
  end

  local function cancelPresses(): ()
    table.clear(presses)
    host.cancel 'control-removed'
  end

  local function describe(clip: ui.Bounds, theme: ui.Theme): { read [number]: ui.ItemDescription }
    local result: { ui.ItemDescription } = {}
    local geometry = current(host.bounds(), theme)
    if kind == 'choice' and not effectiveOpen(geometry) then
      return table.freeze(result)
    end
    local viewport = intersect(geometry.viewport, clip)
    if not viewport then
      return table.freeze(result)
    end
    local scrollOffset = math.clamp(offset, 0, geometry.maximum)
    local stride = theme.rowHeight + theme.spacing
    for index, item in entries do
      local row: ui.Bounds = {
        x = geometry.viewport.x,
        y = geometry.viewport.y + (index - 1) * stride - scrollOffset,
        width = geometry.viewport.width,
        height = theme.rowHeight,
      }
      local visible = intersect(row, viewport)
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

  local function itemAt(event: surface.PointerEvent, id: string?): ui.ItemDescription?
    if id == nil then
      return nil
    end
    for _, item in describe(inputClip or host.bounds(), host.theme()) do
      local bounds = item.bounds
      if item.id == id and item.enabled and bounds and contains(bounds, event.x, event.y) then
        return item
      end
    end
    return nil
  end

  local function setItems(items: Items): ()
    if not host.live() then
      return
    end
    local replacement = snapshot(kind, items)
    entries = replacement
    if selected then
      local retained = false
      for _, item in entries do
        retained = retained or item.id == selected
      end
      if not retained then
        selected = nil
      end
    end
    local geometry = current(host.bounds(), host.theme())
    offset = math.clamp(offset, 0, geometry.maximum)
    opened = opened and geometry.canOpen
    changed()
    cancelPresses()
  end

  local function setSelected(id: string?): ()
    if not host.live() then
      return
    end
    local replacement = selectedId(kind, entries, id)
    if replacement ~= selected then
      selected = replacement
      changed()
    end
  end

  local function setOpen(value: boolean): ()
    if not host.live() then
      return
    end
    if type(value) ~= 'boolean' then
      error('ui ' .. kind .. ': open is a boolean', 2)
    end
    local geometry = current(host.bounds(), host.theme())
    local replacement = value and geometry.canOpen
    if opened == replacement then
      return
    end
    opened = replacement
    offset = math.clamp(offset, 0, geometry.maximum)
    changed()
    cancelPresses()
  end

  -- Both method and pointer scrolling add logical pixels; the pointer provider applies tuning once.
  local function scroll(delta: number): ()
    if not host.live() then
      return
    end
    if not finite(delta) then
      error('ui ' .. kind .. ': scroll delta is a finite number of logical pixels', 2)
    end
    local geometry = current(host.bounds(), host.theme())
    local replacement = math.clamp(math.clamp(offset, 0, geometry.maximum) + delta, 0, geometry.maximum)
    if replacement == offset then
      return
    end
    offset = replacement
    changed()
    cancelPresses()
  end

  local function activate(id: string): ()
    local selectionChanged = selected ~= id
    local closed = kind == 'choice' and opened
    selected = id
    if closed then
      opened = false
    end
    local committedRevision = revision + (if selectionChanged or closed then 1 else 0)
    if selectionChanged or closed then
      changed()
    end
    if closed then
      cancelPresses()
    end
    local callback = onChange
    if not host.live() or revision ~= committedRevision or not selectionChanged or not callback then
      return
    end
    host.callback('ui ' .. kind .. ' onChange', function(): ()
      callback(id)
    end)
  end

  local function pointer(event: surface.PointerEvent, id: string?): ()
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
      local geometry = current(host.bounds(), host.theme())
      if kind == 'list' or effectiveOpen(geometry) then
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
    local geometry = current(host.bounds(), host.theme())
    if event.kind == 'press' then
      if not event.inside or presses[event.pointer] then
        return
      end
      local item = itemAt(event, id)
      if item and item.bounds then
        presses[event.pointer] = { id = item.id, bounds = item.bounds }
      elseif kind == 'choice' and id == nil then
        local target = if effectiveOpen(geometry) then geometry.header else host.bounds()
        local bounds = intersect(target, inputClip or host.bounds())
        if bounds and contains(bounds, event.x, event.y) then
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
      if item and item.id == pressed.id and item.bounds and sameBounds(pressed.bounds, item.bounds) then
        activate(item.id)
      end
    elseif kind == 'choice' and id == nil then
      local target = if effectiveOpen(geometry) then geometry.header else host.bounds()
      local bounds = intersect(target, inputClip or host.bounds())
      if bounds and sameBounds(pressed.bounds, bounds) and contains(bounds, event.x, event.y) then
        setOpen(not effectiveOpen(geometry))
      end
    end
  end

  local function visual(base: ui.Visual): ui.Visual
    local geometry = current(host.bounds(), base.theme)
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
      opened = if kind == 'choice' then effectiveOpen(geometry) else nil,
      overflow = geometry.maximum > 0 and (kind == 'list' or effectiveOpen(geometry)),
      items = describe(base.clip, base.theme),
    }
    return result
  end

  return table.freeze {
    setItems = setItems,
    setSelected = setSelected,
    selected = function(): string?
      return selected
    end,
    setOpen = setOpen,
    scroll = scroll,
    pointer = pointer,
    items = function(clip: ui.Bounds, theme: ui.Theme): { read [number]: ui.ItemDescription }
      inputClip = table.freeze(table.clone(clip))
      return describe(clip, theme)
    end,
    visual = visual,
  }
end

snapshot = function(kind: Kind, source: Items): Items
  local prefix = 'ui ' .. kind .. ': '
  if type(source) ~= 'table' or getmetatable(source) ~= nil then
    error(prefix .. 'items are a plain array', 3)
  end
  local raw = source :: { read [unknown]: unknown }
  local count = 0
  for key in raw do
    if type(key) ~= 'number' or not finite(key) or key < 1 or key % 1 ~= 0 then
      error(prefix .. 'items are a dense array without named fields', 3)
    end
    count += 1
  end
  local seen: { [string]: boolean } = {}
  local result: { ui.Item } = {}
  for index = 1, count do
    local value = raw[index]
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
      error(prefix .. 'item ' .. index .. ' is a plain table', 3)
    end
    local fields = value :: { read [unknown]: unknown }
    for key in fields do
      if key ~= 'id' and key ~= 'label' and key ~= 'enabled' then
        error(prefix .. 'item ' .. index .. ' has an unknown field ' .. tostring(key), 3)
      end
    end
    local id, label, enabled = fields.id, fields.label, fields.enabled
    if type(id) ~= 'string' or id == '' then
      error(prefix .. 'item ' .. index .. ' id is a nonempty string', 3)
    end
    if seen[id] then
      error(prefix .. 'duplicate item id ' .. string.format('%q', id), 3)
    end
    if type(label) ~= 'string' then
      error(prefix .. 'item ' .. index .. ' label is a string', 3)
    end
    if enabled ~= nil and type(enabled) ~= 'boolean' then
      error(prefix .. 'item ' .. index .. ' enabled is a boolean', 3)
    end
    seen[id] = true
    local item: ui.Item = table.freeze { id = id, label = label, enabled = enabled ~= false }
    table.insert(result, item)
  end
  return table.freeze(result)
end

selectedId = function(kind: Kind, items: Items, id: string?): string?
  if id == nil then
    return nil
  end
  if type(id) == 'string' then
    for _, item in items do
      if item.id == id then
        return id
      end
    end
  end
  error('ui ' .. kind .. ': selected names an existing item id or is nil', 3)
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

intersect = function(a: ui.Bounds, b: ui.Bounds): ui.Bounds?
  local x, y = math.max(a.x, b.x), math.max(a.y, b.y)
  local right, bottom = math.min(a.x + a.width, b.x + b.width), math.min(a.y + a.height, b.y + b.height)
  if right <= x or bottom <= y then
    return nil
  end
  return table.freeze { x = x, y = y, width = right - x, height = bottom - y }
end

contains = function(bounds: ui.Bounds, x: number?, y: number?): boolean
  return x ~= nil
    and y ~= nil
    and x >= bounds.x
    and x < bounds.x + bounds.width
    and y >= bounds.y
    and y < bounds.y + bounds.height
end

sameBounds = function(a: ui.Bounds, b: ui.Bounds): boolean
  return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

finite = function(value: unknown): boolean
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

return collection
