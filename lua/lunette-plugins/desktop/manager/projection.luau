-- Projects native allocation records into graph edges without inferring providers from declarations.

local lunette = require '@lunette'
local graph = require './graph'
local projection = {}

export type Projected = {
  read graph: graph.Snapshot,
  read instances: { read [string]: lunette.PluginInstanceSnapshot },
  read bindings: { read [string]: lunette.PluginBindingSnapshot },
}

function projection.snapshot(snapshot: lunette.PluginRuntimeSnapshot): Projected
  local nodes: { graph.Node } = {}
  local edges: { graph.Edge } = {}
  local instances: { [string]: lunette.PluginInstanceSnapshot } = {}
  local bindings: { [string]: lunette.PluginBindingSnapshot } = {}
  for _, instance in snapshot.instances do
    instances[instance.id] = instance
    local detail: { string } = {}
    for _, capability in instance.required do
      detail[#detail + 1] = capability.field .. ': ' .. capability.contract.display
    end
    for _, capability in instance.provided do
      detail[#detail + 1] = capability.field .. ': ' .. capability.contract.display
    end
    for _, blocker in instance.blockers do
      detail[#detail + 1] = blocker.message
    end
    if instance.diagnostic then
      detail[#detail + 1] = instance.diagnostic
    end
    nodes[#nodes + 1] = table.freeze {
      id = instance.id,
      name = instance.name,
      state = instance.state,
      enabled = instance.enabled,
      detail = table.concat(detail, '\n'),
    }
  end
  for _, instance in snapshot.instances do
    if instance.parentId and instances[instance.parentId] then
      edges[#edges + 1] = table.freeze {
        id = 'owner:' .. instance.id .. ':' .. instance.parentId,
        kind = 'ownership' :: 'ownership',
        from = instance.id,
        to = instance.parentId,
        label = 'owned by',
      }
    end
    for index, binding in instance.bindings do
      if instances[binding.providerId] then
        local id = 'binding:' .. instance.id .. ':' .. binding.providerId .. ':' .. binding.generationId .. ':' .. index
        local edge: graph.Edge = table.freeze {
          id = id,
          kind = 'dependency' :: 'dependency',
          from = instance.id,
          to = binding.providerId,
          label = binding.contract.display,
          generation = binding.generationId,
        }
        edges[#edges + 1] = edge
        bindings[id] = binding
      end
    end
  end
  return table.freeze {
    graph = table.freeze { nodes = table.freeze(nodes), edges = table.freeze(edges) },
    instances = table.freeze(instances),
    bindings = table.freeze(bindings),
  }
end

return projection
