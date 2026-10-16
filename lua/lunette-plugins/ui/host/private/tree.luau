-- Reconciles element trees into node records, expands composites, and records the native layout changes they need.
-- Children match by slot and kind; a node whose element is the same table as before, and which is not dirty, keeps
-- its whole subtree.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'
local handles = require './handles'
local theme = require './theme'

local tree = {}

type Environment = records.Environment

local function push(panel: records.Panel, change: lunette.LayoutChange): ()
  panel.changes[#panel.changes + 1] = change
end

local createNode: (records.Panel, Environment, records.Node?, uiHost.Element, string) -> records.Node
local updateNode: (records.Panel, Environment, records.Node, uiHost.Element) -> ()
local removeNode: (records.Panel, Environment, records.Node) -> ()

-- Reconciles the panel's root against an element, or removes the content for nil. An overlay's root has the portal
-- node as its logical parent, so events bubble out of the overlay into the panel that opened it.
function tree.submit(panel: records.Panel, env: Environment, element: uiHost.Element?, parent: records.Node?): ()
  local root = panel.root
  if root and (element == nil or root.kind ~= env.kind(element.kind) or root.key ~= element.key) then
    removeNode(panel, env, root)
    panel.root = nil
    root = nil
  end
  if element == nil then
    return
  end
  if root then
    updateNode(panel, env, root, element)
  else
    panel.root = createNode(panel, env, parent, element, element.key or '#root')
  end
end

-- Re-expands or restyles every dirty node, so state changes reach layout without a framework render.
function tree.refresh(panel: records.Panel, env: Environment): ()
  local function visit(node: records.Node): ()
    if node.dirty then
      updateNode(panel, env, node, node.element)
    end
    for _, child in table.clone(node.children) do
      visit(child)
    end
  end
  local root = panel.root
  if root and root.kind ~= env.kind(root.element.kind) then
    -- The root's kind was registered again or removed, so the root is made again from its element.
    tree.submit(panel, env, root.element, root.parent)
  elseif root then
    visit(root)
  end
end

-- Marks every node dirty, as a theme change requires.
function tree.invalidate(panel: records.Panel): ()
  for _, node in panel.nodes do
    node.dirty = true
    node.primitives = nil
  end
  panel.dirty = true
end

local function equal(first: any, second: any): boolean
  if first == second then
    return true
  end
  if type(first) ~= 'table' or type(second) ~= 'table' then
    return false
  end
  for name, value in first do
    if not equal(value, second[name]) then
      return false
    end
  end
  for name in second do
    if first[name] == nil then
      return false
    end
  end
  return true
end

-- Resolved layout inputs for a node: the native kind, its style, and, for a text node, its text and text style.
type Resolved = {
  native: 'box' | 'text',
  style: lunette.LayoutStyle,
  text: string?,
  textStyle: lunette.LayoutTextStyle?,
  elevation: number,
}

local DEFAULT_STYLE: lunette.LayoutStyle = { flexDirection = 'column', alignItems = 'stretch' }

-- Validates the node's props against its kind's schema, reporting what does not fit.
local function validate(env: Environment, node: records.Node): ()
  local descriptor = node.kind.registration.props
  if descriptor then
    env.protect(`ui: {node.kind.name} props`, function(): ()
      descriptor.parse(node.props, node.kind.name)
    end)
  end
end

local function resolve(env: Environment, node: records.Node): Resolved
  local registration = node.kind.registration
  local layout = registration.layout
  local tokens = env.theme()
  -- A kind without a layout, such as most composites, stacks its children and stretches them across its width.
  local resolved: Resolved = { native = 'box', style = DEFAULT_STYLE, elevation = 0 }
  local label = `ui: {node.kind.name} layout`
  env.protect(label, function(): ()
    if layout == nil then
      return
    end
    if layout.kind == 'text' then
      local text = layout.text(node.props, tokens)
      assert(type(text) == 'string', 'the text function returns a string')
      resolved = {
        native = 'text',
        style = if layout.style then layout.style(node.props, tokens) else {},
        text = text,
        textStyle = layout.textStyle(node.props, tokens),
        elevation = 0,
      }
    elseif layout.kind == 'container' then
      if layout.style then
        resolved.style = layout.style(node.props, tokens, node.state)
      end
    elseif layout.kind == 'leaf' then
      if layout.style then
        resolved.style = layout.style(node.props, tokens)
      end
    end
  end)
  local elevation = registration.elevation
  env.protect(`ui: {node.kind.name} elevation`, function(): ()
    if type(elevation) == 'function' then
      resolved.elevation = elevation(node.props, tokens)
    elseif elevation ~= nil then
      resolved.elevation = theme.length(tokens.elevation, elevation, 0)
    end
  end)
  return resolved
end

-- A failed expansion gives nil, and the composite keeps its children until it expands again.
local function expansion(env: Environment, node: records.Node): ({ read [number]: uiHost.Element }?, { string })
  local expand = assert(node.kind.registration.expand)
  local elements: { uiHost.Element }?, slots: { string } = nil, {}
  env.protect(`ui: {node.kind.name} expand`, function(): ()
    -- The handle's state includes host state, such as focus and hover, so a composite can show it.
    local produced = expand(node.props, node.element.children, node.handle.state, handles.actions(node))
    elements, slots = uiHost.children(produced :: any)
  end)
  return elements, slots
end

local function childElements(env: Environment, node: records.Node): ({ read [number]: uiHost.Element }?, { string })
  if node.kind.composite then
    return expansion(env, node)
  end
  local element = node.element
  local slots: { string } = {}
  for index, child in element.children do
    slots[index] = if element.slots then element.slots[index] else child.key or '#' .. index
  end
  return element.children, slots
end

local function reconcileChildren(panel: records.Panel, env: Environment, node: records.Node): ()
  if node.text ~= nil then
    return
  end
  if node.kind.portal then
    env.portal(panel, node)
    return
  end
  local elements, slots = childElements(env, node)
  if elements == nil then
    return
  end
  local previous: { [string]: records.Node } = {}
  for _, child in node.children do
    previous[child.slot] = child
  end
  local seen: { [string]: boolean } = {}
  local children: { records.Node } = {}
  for index, element in elements do
    local slot = slots[index]
    if seen[slot] then
      env.protect(`ui: {node.kind.name} children`, function(): ()
        error(`two children share the key '{slot}'`, 0)
      end)
      continue
    end
    seen[slot] = true
    local existing = previous[slot]
    -- The registration is compared, not the name, so a kind registered again replaces the nodes made from the old one.
    if existing and existing.kind == env.kind(element.kind) then
      previous[slot] = nil
      updateNode(panel, env, existing, element)
      children[#children + 1] = existing
    else
      children[#children + 1] = createNode(panel, env, node, element, slot)
    end
  end
  for _, stale in previous do
    removeNode(panel, env, stale)
  end
  local changed = #children ~= #node.children
  if not changed then
    for index, child in children do
      if node.children[index] ~= child then
        changed = true
        break
      end
    end
  end
  node.children = children
  if changed then
    local ids: { number } = {}
    for index, child in children do
      ids[index] = child.id
    end
    push(panel, { op = 'children', id = node.id, children = ids })
  end
end

local function restyle(panel: records.Panel, env: Environment, node: records.Node): ()
  local resolved = resolve(env, node)
  node.elevation = resolved.elevation
  if not equal(resolved.style, node.style) then
    node.style = resolved.style
    push(panel, { op = 'style', id = node.id, style = resolved.style })
  end
  if resolved.native == 'text' and node.text ~= nil then
    local text = resolved.text or ''
    if text ~= node.text or not equal(resolved.textStyle, node.textStyle) then
      node.text, node.textStyle = text, resolved.textStyle
      push(panel, { op = 'text', id = node.id, text = text, textStyle = resolved.textStyle })
    end
  end
end

createNode = function(
  panel: records.Panel,
  env: Environment,
  parent: records.Node?,
  element: uiHost.Element,
  slot: string
): records.Node
  local kind = env.kind(element.kind)
  local registration = kind.registration
  local id = panel.nextId
  panel.nextId += 1
  local state: { [string]: any } = {}
  if registration.state then
    for name, value in registration.state do
      state[name] = value
    end
  end
  local node: records.Node = {
    id = id,
    kind = kind,
    key = element.key,
    slot = slot,
    element = element,
    props = element.props,
    state = state,
    host = { hovers = 0, pressed = false, dragging = false, focused = false, focusVisible = false, engaged = false },
    parent = parent,
    children = {},
    panel = panel,
    u = 0,
    v = 0,
    style = nil,
    text = nil,
    textStyle = nil,
    x = 0,
    y = 0,
    width = 0,
    height = 0,
    elevation = 0,
    lift = 0,
    liftTarget = 0,
    z = 0,
    primitives = nil,
    dirty = false,
    handle = nil :: any,
    ref = element.ref,
    dead = false,
  }
  node.handle = handles.new(node, env)
  panel.nodes[id] = node
  validate(env, node)
  local resolved = resolve(env, node)
  node.style = resolved.style
  node.elevation = resolved.elevation
  if resolved.native == 'text' then
    node.text, node.textStyle = resolved.text or '', resolved.textStyle
    push(panel, {
      op = 'create',
      id = id,
      kind = 'text',
      style = resolved.style,
      text = node.text,
      textStyle = resolved.textStyle,
    })
  else
    push(panel, { op = 'create', id = id, kind = 'box', style = resolved.style })
  end
  reconcileChildren(panel, env, node)
  if node.ref then
    node.ref.current = node.handle
  end
  return node
end

updateNode = function(panel: records.Panel, env: Environment, node: records.Node, element: uiHost.Element): ()
  if element == node.element and not node.dirty then
    return
  end
  local changedProps = element.props ~= node.props
  node.element = element
  node.props = element.props
  node.dirty = false
  if changedProps then
    validate(env, node)
  end
  node.primitives = nil
  if element.ref ~= node.ref then
    if node.ref then
      node.ref.current = nil
    end
    node.ref = element.ref
    if node.ref then
      node.ref.current = node.handle
    end
  end
  handles.refresh(node, env)
  restyle(panel, env, node)
  reconcileChildren(panel, env, node)
end

removeNode = function(panel: records.Panel, env: Environment, node: records.Node): ()
  if node.overlay then
    env.unportal(node)
  end
  for _, child in node.children do
    removeNode(panel, env, child)
  end
  node.children = {}
  node.dead = true
  panel.nodes[node.id] = nil
  push(panel, { op = 'remove', id = node.id })
  if node.ref and node.ref.current == node.handle then
    node.ref.current = nil
  end
  handles.refresh(node, env)
  env.removed(panel, node)
end

return tree
