local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-contracts/schemas/theme'

local positive = schema.number { positive = true }
local count = schema.number { minimum = 1, integer = true }
local color = descriptors.color

local descriptor = schema.object {
  -- Capabilities whose provider must be active for the toolkit to work: the host, and the components plugin, which
  -- registers the standard kinds.
  toolkit = schema.default(schema.array(schema.string())) { 'lunette/ui-host', 'lunette/ui-components' },
  -- Error reports whose message starts with one of these prefixes count as the host's. The error stream carries no
  -- owner, and the host reports its own failures under the `ui:` context.
  hostErrorPrefixes = schema.default(schema.array(schema.string())) { 'ui:' },
  -- Consecutive frames with host errors before the panel shows. A failure on every frame for about a second is not a
  -- transient one.
  errorFrames = schema.default(count)(90),
  -- Consecutive frames without host errors before a panel shown for errors hides again.
  quietFrames = schema.default(count)(180),
  -- Seconds the toolkit stays active and free of host errors, under an unchanged composition, before the composition
  -- is marked as the last known good one.
  healthySeconds = schema.default(schema.number { minimum = 0 })(10),
  -- Seconds between reads of the composition. Host errors are counted on every frame.
  pollSeconds = schema.default(schema.number { minimum = 0 })(0.25),
  recentErrors = schema.default(count)(4),
  columns = schema.default(count)(64),
  -- Metres in front of the head, along its horizontal facing, where the panel appears when it shows.
  distance = schema.default(positive)(0.7),
  -- Metres below the head.
  drop = schema.default(schema.number())(0.15),
  width = schema.default(positive)(0.7),
  -- Picking prefers the panel over surfaces with a lower priority, whatever their distance.
  pickPriority = schema.default(schema.number())(1000),
  background = schema.default(color) { 0.08, 0.08, 0.1, 0.96 },
  foreground = schema.default(color) { 1, 1, 1, 1 },
  button = schema.default(color) { 0.2, 0.32, 0.55, 1 },
  hovered = schema.default(color) { 0.3, 0.45, 0.75, 1 },
  disabled = schema.default(color) { 0.25, 0.25, 0.28, 1 },
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
