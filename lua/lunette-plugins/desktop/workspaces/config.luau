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
  workspaces = defaultList(workspaces) { { name = 'main' }, { name = 'two' }, { name = 'three' }, { name = 'four' } },
  follow = schema.default(schema.boolean())(true),
}
local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

local function checkRemovedFields(value: unknown, name: string?): ()
  if type(value) ~= 'table' then
    return
  end
  local fields = value :: { [string]: unknown }
  local prefix = if name then 'plugin ' .. name .. ': ' else ''
  if rawget(fields, 'modifiers') ~= nil then
    error(prefix .. 'workspaces modifiers are removed; choose workspaces from the session menu', 0)
  end
  local entries = rawget(fields, 'workspaces')
  if type(entries) ~= 'table' then
    return
  end
  for _, entry in entries :: { [unknown]: unknown } do
    if type(entry) == 'table' and rawget(entry :: { [string]: unknown }, 'key') ~= nil then
      error(prefix .. 'workspaces key is removed; choose workspaces from the session menu', 0)
    end
  end
end

-- Keep the descriptor token and witnesses without exposing removed settings as editable fields.
local checked = table.clone((descriptor :: unknown) :: { [string]: unknown })
checked.parse = function(value: unknown, name: string?): Settings
  checkRemovedFields(value, name)
  return descriptor.parse(value, name)
end
checked.resolve = function(value: unknown, base: Settings, name: string?): Settings
  checkRemovedFields(value, name)
  checkRemovedFields(base, name)
  return descriptor.resolve(value, base, name)
end

return { schema = (table.freeze(checked) :: unknown) :: typeof(descriptor) }
