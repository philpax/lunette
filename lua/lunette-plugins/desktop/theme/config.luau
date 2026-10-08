local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-plugins/theme/descriptors'

local preset = schema.union(
  schema.literal<<'dark'>> 'dark',
  schema.union(schema.literal<<'light'>> 'light', schema.literal<<'arcade'>> 'arcade')
)
local descriptor = schema.object {
  preset = schema.default(preset) 'dark',
  overrides = schema.default(descriptors.editableOverrides) {},
}

export type Preset = schema.Output<typeof(preset)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
