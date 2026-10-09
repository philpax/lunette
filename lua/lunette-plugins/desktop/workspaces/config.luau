local schema = require '@lunette-plugin/schema'

local nameList = schema.array(schema.string { minLength = 1 }, { minLength = 1 })
local refineList = (schema.refine :: unknown) :: (
  typeof(nameList)
) -> (({ read [number]: string }) -> (), string?) -> typeof(nameList)
local names = refineList(nameList)(function(value: { read [number]: string }): ()
  local seen: { [string]: boolean } = {}
  for _, name in value do
    assert(not seen[name], 'workspace name ' .. name .. ' occurs twice')
    seen[name] = true
  end
end, 'Workspace names are unique.')
local shape = {
  names = schema.default(names) { 'main' },
  follow = schema.default(schema.boolean())(true),
}
local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
