-- Roles, semantics, and ids of nodes, for inspection, tests, and assistive plugins. Inspection runs no consumer
-- callback: a kind's semantics function belongs to the kind's owner and runs under a protected call.

local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'

local semantics = {}

-- A node's id: its panel's name, then the keys or slots on its path from the content root.
function semantics.id(node: records.Node): string
  local segments: { string } = {}
  local current: records.Node? = node
  while current and current.panel == node.panel do
    table.insert(segments, 1, current.key or current.slot)
    current = current.parent
  end
  table.remove(segments, 1)
  return node.panel.name .. ':' .. table.concat(segments, '/')
end

-- The node's semantics: the kind's own, or a name from the common label props.
function semantics.of(env: records.Environment, node: records.Node): uiHost.Semantics
  local registration = node.kind.registration
  local result: uiHost.Semantics = {}
  if registration.semantics then
    env.protect(`ui: {node.kind.name} semantics`, function(): ()
      result = registration.semantics(node.props, node.handle.state)
    end)
  end
  if result.name == nil then
    local props = node.props
    local name = props.label or props.title or props.text
    if type(name) == 'string' then
      result = table.clone(result) :: any
      (result :: any).name = name
    end
  end
  return result
end

-- The role of a node: its kind's, or for a composite without one, the role of the node its expansion starts with.
function semantics.role(node: records.Node): uiHost.Role?
  local role = node.kind.registration.role
  if role == nil and node.kind.composite and #node.children == 1 then
    return semantics.role(node.children[1])
  end
  return role
end

-- Every node of the panels that has a role, in tree order.
function semantics.nodes(panels: { records.Panel }): { records.Node }
  local list: { records.Node } = {}
  local function visit(node: records.Node): ()
    if node.kind.registration.role then
      table.insert(list, node)
    end
    for _, child in node.children do
      visit(child)
    end
  end
  for _, panel in panels do
    if panel.root and not panel.dead then
      visit(panel.root)
    end
  end
  return list
end

return semantics
