local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-plugins/theme/configuration'

-- The preset names a catalog theme; the set is open, so a name is checked against the catalog at runtime.
local descriptor = schema.object {
  preset = schema.default(schema.string { minLength = 1 }) 'dark',
  overrides = schema.default(descriptors.editableOverrides) {},
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
