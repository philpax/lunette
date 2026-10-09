local schema = require '@lunette-plugin/schema'

local workspace = schema.object { name = schema.string { minLength = 1 } }
export type WorkspaceInput = schema.Input<typeof(workspace)>
export type Workspace = schema.Output<typeof(workspace)>
local workspaceList = schema.array<<typeof(workspace)>>(workspace, { minLength = 1 })
local refineList = (schema.refine :: unknown) :: (
  typeof(workspaceList)
) -> (({ read [number]: Workspace }) -> (), string?) -> typeof(workspaceList)
local workspaces = refineList(workspaceList)(function(value: { read [number]: Workspace }): ()
  local seen: { [string]: boolean } = {}
  for _, entry in value do
    assert(not seen[entry.name], 'workspace name ' .. entry.name .. ' occurs twice')
    seen[entry.name] = true
  end
end, 'Workspace names are unique.')
local defaultList = (schema.default :: unknown) :: (
  typeof(workspaceList)
) -> ({ read [number]: Workspace }) -> schema.Schema<{ WorkspaceInput }?, { read [number]: Workspace }>
local shape = {
  workspaces = defaultList(workspaces) { { name = 'main' } },
  follow = schema.default(schema.boolean())(true),
}
local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
