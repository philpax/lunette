-- Node handles: what kinds, visuals, and ref holders see of a node record.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'
local shape = require './shape'

local handles = {}

type Fields = {
  id: number,
  kind: string,
  key: string?,
  props: uiHost.Props,
  state: { [string]: any },
  bounds: uiHost.Rect,
  theme: uiHost.Theme,
  dead: boolean,
  parent: uiHost.Node?,
}

-- Kind state updates merge into the node's state and mark it for re-expansion or restyling at the next commit.
function handles.setState(node: records.Node, update: any): ()
  if node.dead then
    return
  end
  local changes: any = if type(update) == 'function' then (update :: (any) -> any)(table.clone(node.state)) else update
  assert(type(changes) == 'table', 'ui: setState takes a table of fields or a function returning one')
  local changed = false
  for name, value in changes do
    if node.state[name] ~= value then
      node.state[name] = value
      changed = true
    end
  end
  if changed then
    node.dirty = true
    node.primitives = nil
    node.panel.dirty = true
    handles.refreshState(node, node.handle)
  end
end

-- Programmatic scrolling. A scrolling node is one that clips and declares a scrollY state, which the host subtracts
-- from its children's positions; a node that only clips, such as an outlet with a maximum height, does not scroll.
function handles.scrolls(node: records.Node): boolean
  return node.kind.registration.clip == true and type(node.state.scrollY) == 'number'
end

-- How far a scrolling node's content scrolls: its children's extent less its own height.
local function limit(node: records.Node): number
  local height = 0
  for _, child in node.children do
    height = math.max(height, child.v + child.height - node.v)
  end
  return math.max(height - node.height, 0)
end

-- Sets a scrolling node's offset, held within its content.
function handles.scrollTo(node: records.Node, offset: number): ()
  assert(handles.scrolls(node), `ui: {node.kind.name} does not scroll`)
  assert(type(offset) == 'number' and offset == offset, 'ui: a scroll offset is a number')
  handles.setState(node, { scrollY = math.clamp(offset, 0, limit(node)) })
end

-- Scrolls each scrolling ancestor, innermost first, by the least that brings the node, with a margin around it,
-- inside the ancestor's box. Positions are layout positions, which ignore scrolling, so each ancestor's new offset
-- moves the node for the ancestors outside it.
function handles.scrollIntoView(node: records.Node, margin: number): ()
  local top, bottom = node.v - margin, node.v + node.height + margin
  local ancestor = node.parent
  while ancestor and ancestor.panel == node.panel do
    if handles.scrolls(ancestor) then
      local offset = ancestor.state.scrollY :: number
      local start, finish = ancestor.v + offset, ancestor.v + offset + ancestor.height
      if top < start then
        offset = top - ancestor.v
      elseif bottom > finish then
        offset = math.min(bottom - ancestor.v - ancestor.height, top - ancestor.v)
      end
      offset = math.clamp(offset, 0, limit(ancestor))
      handles.setState(ancestor, { scrollY = offset })
      top, bottom = top - offset, bottom - offset
    end
    ancestor = ancestor.parent
  end
end

local function emit(node: records.Node, env: records.Environment, name: string, ...: any): ()
  if node.dead then
    return
  end
  local callback = node.props[name]
  if type(callback) == 'function' then
    local arguments = table.pack(...)
    env.protect(`ui: {node.kind.name} {name}`, function(): ()
      (callback :: (...any) -> ())(table.unpack(arguments, 1, arguments.n))
    end)
  end
  if name == 'onChange' then
    local parent = node.parent
    if parent and not parent.dead then
      env.dispatch(parent, { kind = 'change', key = node.key, value = (...) })
    end
  end
end

function handles.new(node: records.Node, env: records.Environment): uiHost.Node
  local fields: Fields = {
    id = node.id,
    kind = node.kind.name,
    key = node.key,
    props = node.props,
    state = {},
    bounds = { x = 0, y = 0, width = 0, height = 0 },
    theme = env.theme(),
    dead = false,
    parent = if node.parent then node.parent.handle else nil,
  }
  local handle = fields :: any
  handle.emit = function(_self: uiHost.Node, name: string, ...: any): ()
    emit(node, env, name, ...)
  end
  handle.setState = function(_self: uiHost.Node, update: any): ()
    handles.setState(node, update)
  end
  handle.panelBounds = function(_self: uiHost.Node): uiHost.Rect
    return { x = node.x, y = node.y, width = node.width, height = node.height }
  end
  handle.pose = function(_self: uiHost.Node): Mat4
    return shape.frame(node.panel, node.x + node.width / 2, node.y + node.height / 2, node.z)
  end
  handle.animate = function(_self: uiHost.Node, name: string, target: number): ()
    assert(type(target) == 'number' and target == target, 'ui: a channel target is a number')
    local channel = node.channels[name]
    if not channel then
      channel = { value = if name == 'opacity' then 1 else 0, target = target, velocity = 0 }
      node.channels[name] = channel
    end
    channel.target = target
  end
  handle.channel = function(_self: uiHost.Node, name: string): number
    local channel = node.channels[name]
    return if channel then channel.value elseif name == 'opacity' then 1 else 0
  end
  handle.scrollTo = function(_self: uiHost.Node, offset: number): ()
    handles.scrollTo(node, offset)
  end
  handle.scrollBy = function(_self: uiHost.Node, delta: number): ()
    assert(type(delta) == 'number' and delta == delta, 'ui: a scroll distance is a number')
    handles.scrollTo(node, (node.state.scrollY or 0) + delta)
  end
  handle.scrollIntoView = function(_self: uiHost.Node): ()
    handles.scrollIntoView(node, env.theme().spacing.sm)
  end
  handle.focus = function(_self: uiHost.Node): boolean
    return env.focusNode(node, true)
  end
  handle.blur = function(_self: uiHost.Node): ()
    env.blurNode(node)
  end
  handle.descendant = function(_self: uiHost.Node, path: string): uiHost.Node?
    local current: records.Node? = node
    for segment in string.gmatch(path, '[^/]+') do
      local function search(parent: records.Node): records.Node?
        for _, candidate in parent.children do
          if candidate.key == segment then
            return candidate
          end
        end
        for _, candidate in parent.children do
          if candidate.key == nil then
            local found = search(candidate)
            if found then
              return found
            end
          end
        end
        return nil
      end
      current = if current then search(current) else nil
    end
    return if current and not current.dead then current.handle else nil
  end
  handle.textLines = function(_self: uiHost.Node): { lunette.LayoutLine }?
    if node.dead or node.text == nil then
      return nil
    end
    return node.panel.tree:textLayout(node.id)
  end
  handle.contentSize = function(_self: uiHost.Node): (number, number)
    local width, height = 0, 0
    for _, child in node.children do
      width = math.max(width, child.u + child.width - node.u)
      height = math.max(height, child.v + child.height - node.v)
    end
    return width, height
  end
  handles.refreshState(node, handle)
  return handle :: uiHost.Node
end

-- Copies the record's current props, state, theme, and liveness onto its handle.
function handles.refresh(node: records.Node, env: records.Environment): ()
  local fields = node.handle :: any
  fields.props = node.props
  fields.theme = env.theme()
  fields.dead = node.dead
  handles.refreshState(node, fields)
end

-- Marks a node whose host state changed for redrawing, and a composite for expanding again.
function handles.hostChanged(node: records.Node): ()
  node.primitives = nil
  if node.kind.composite then
    node.dirty = true
    node.panel.dirty = true
  end
  handles.refreshState(node, node.handle)
end

function handles.refreshState(node: records.Node, handle: any): ()
  local state = table.clone(node.state)
  state.hovered = node.host.hovers > 0
  state.pressed = node.host.pressed
  state.dragging = node.host.dragging
  state.focused = node.host.focused
  state.focusVisible = node.host.focusVisible
  state.engaged = node.host.engaged
  handle.state = table.freeze(state)
end

function handles.refreshBounds(node: records.Node): ()
  local fields = node.handle :: any
  fields.bounds = table.freeze { x = 0, y = 0, width = node.width, height = node.height }
end

function handles.actions(node: records.Node): uiHost.Actions
  return {
    setState = function(update: any): ()
      handles.setState(node, update)
    end,
    emit = function(name: string, ...: any): ()
      node.handle:emit(name, ...)
    end,
  }
end

return handles
