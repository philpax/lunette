local schema = require '@lunette-plugin/schema'
local bindings = require '@lunette-plugins/desktop/bindings/config'

local workspaceShape: { read name: schema.Schema<string, string>, read key: schema.Schema<KeyCode, KeyCode> } = {
  name = schema.string { minLength = 1 },
  key = bindings.key,
}
local workspace = schema.object<<typeof(workspaceShape)>>(workspaceShape)
export type WorkspaceInput = schema.Input<typeof(workspace)>
export type Workspace = schema.Output<typeof(workspace)>
-- Typed constructor aliases retain KeyCode without repeatedly expanding its union.
local workspaceList = (
  schema.array<<typeof(workspace)>>(workspace, { minLength = 1 }) :: unknown
) :: schema.Schema<{ WorkspaceInput }, { read [number]: Workspace }>
local refineList = (schema.refine :: unknown) :: (
  schema.Schema<{ WorkspaceInput }, { read [number]: Workspace }>
) -> (({ read [number]: Workspace }) -> (), string?) -> schema.Schema<{ WorkspaceInput }, { read [number]: Workspace }>
local workspaces = refineList(workspaceList)(function(value: { read [number]: Workspace }): ()
  local seen: { [string]: boolean } = {}
  for _, entry in value do
    assert(not seen[entry.name], 'workspace name ' .. entry.name .. ' occurs twice')
    seen[entry.name] = true
  end
end, 'Workspace names are unique.')
local defaultList = (schema.default :: unknown) :: (
  schema.Schema<{ WorkspaceInput }, { read [number]: Workspace }>
) -> ({ read [number]: Workspace }) -> schema.Schema<{ WorkspaceInput }?, { read [number]: Workspace }>
local shape: {
  read workspaces: schema.Schema<{ WorkspaceInput }?, { read [number]: Workspace }>,
  read modifiers: schema.Schema<{ string }?, { read [number]: string }>,
  read follow: schema.Schema<boolean?, boolean>,
} =
  {
    workspaces = defaultList(workspaces) {
      { name = 'main', key = '1' },
      { name = 'two', key = '2' },
      { name = 'three', key = '3' },
      { name = 'four', key = '4' },
    },
    modifiers = schema.default(schema.array(schema.string())) { 'logo' },
    follow = schema.default(schema.boolean())(true),
  }

local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = (descriptor :: unknown) :: schema.Schema<Config, Settings> }
