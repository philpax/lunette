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
local function setState(node: records.Node, update: any): ()
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
    setState(node, update)
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
      setState(node, update)
    end,
    emit = function(name: string, ...: any): ()
      node.handle:emit(name, ...)
    end,
  }
end

return handles
