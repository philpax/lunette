local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'

local function adoptEvery(_window: lunette.Window): boolean
  return true
end

local descriptor = schema.object {
  -- Workspaces add an adopted window that has no workspace tag to the selected workspace.
  tags = schema.default(schema.array(schema.string { minLength = 1 })) {},
  filter = schema.default(schema.callback(adoptEvery))(adoptEvery),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
