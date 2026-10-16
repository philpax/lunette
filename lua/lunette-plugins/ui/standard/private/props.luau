-- Prop schemas shared by the standard kinds: colours, lengths, options, and the layout props of containers.

local schema = require '@lunette-plugin/schema'

local props = {}

-- The runtime type check has already established that the value is a texture.
local function texture(value: unknown): Texture
  return value :: Texture
end

-- A colour role name, or a colour as an array of components.
props.color = schema.union { schema.string(), schema.array(schema.number()) }

-- A spacing token name, or metres.
props.space = schema.union { schema.string(), schema.number() }

-- A length in metres, or a percentage string the layout engine accepts.
props.length = schema.union { schema.number(), schema.string() }

props.text = schema.union { schema.string(), schema.number() }

props.align = schema.enum { 'start', 'end', 'center', 'stretch', 'baseline', 'flex-start', 'flex-end' }
props.justify = schema.enum {
  'start',
  'end',
  'center',
  'stretch',
  'space-between',
  'space-around',
  'space-evenly',
  'flex-start',
  'flex-end',
}
props.textAlign = schema.enum { 'start', 'center', 'end' }

props.variant = schema.enum { 'default', 'primary', 'quiet', 'band', 'selected' }

props.activate = schema.callback(function() end)
props.hover = schema.callback(function(_hovered: boolean) end)

-- A choice among options. The id keys the option and is what `onChange` receives.
props.option = schema.object {
  id = schema.string(),
  label = schema.string(),
  detail = schema.optional(schema.string()),
  disabledReason = schema.optional(schema.string()),
}

props.detent = schema.object { value = schema.number(), label = schema.string() }

props.level = schema.enum { 'info', 'warning', 'error' }

-- An image source: an SVG document, an image file, or a texture the caller keeps alive.
props.image = schema.union {
  schema.object { kind = schema.literal 'svg', data = schema.string() },
  schema.object { kind = schema.literal 'file', path = schema.string() },
  schema.object {
    kind = schema.literal 'texture',
    texture = schema.custom<<Texture>> { runtimeType = 'userdata', validate = texture },
  },
}

props.dialogAction = schema.object {
  id = schema.string(),
  label = schema.string(),
  variant = schema.optional(props.variant),
  onActivate = schema.optional(props.activate),
  disabledReason = schema.optional(schema.string()),
}

props.toastAction = schema.object {
  id = schema.string(),
  label = schema.string(),
  onActivate = schema.optional(props.activate),
}

props.listItem = schema.object {
  id = schema.string(),
  title = schema.optional(schema.string()),
  detail = schema.optional(schema.string()),
  trailing = schema.optional(schema.string()),
}

props.column = schema.object {
  id = schema.string(),
  label = schema.string(),
  width = schema.optional(schema.number()),
}

props.tableRow = schema.object { id = schema.string(), cells = schema.array(schema.string()) }

props.tab = schema.object { id = schema.string(), label = schema.string() }

-- The props that disable a control and say why.
local DISABLING = {
  disabled = schema.optional(schema.boolean()),
  disabledReason = schema.optional(schema.string()),
}

-- The layout props that `tokens.container` reads.
local CONTAINER = {
  gap = schema.optional(props.space),
  padding = schema.optional(props.space),
  align = schema.optional(props.align),
  justify = schema.optional(props.justify),
  grow = schema.optional(schema.number()),
  shrink = schema.optional(schema.number()),
  wrap = schema.optional(schema.boolean()),
  width = schema.optional(props.length),
  height = schema.optional(props.length),
  minWidth = schema.optional(props.length),
  maxWidth = schema.optional(props.length),
  alignSelf = schema.optional(props.align),
}

local function merged(base: { [string]: any }, extra: { [string]: any }?): { [string]: any }
  local shape = table.clone(base)
  for name, descriptor in extra or {} do
    assert(shape[name] == nil, `ui standard: prop {name} is declared twice`)
    shape[name] = descriptor
  end
  return shape
end

-- An object schema for a control that can be disabled, with the control's own props.
function props.disableable(shape: { [string]: any }?): any
  return schema.object(merged(DISABLING, shape))
end

-- An object schema for a container, with the container's own props.
function props.container(shape: { [string]: any }?): any
  return schema.object(merged(CONTAINER, shape))
end

return props
