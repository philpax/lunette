local schema = require '@lunette-plugin/schema'

local placement = schema.object {
  distance = schema.default(schema.number())(0.55),
  drop = schema.default(schema.number())(0.35),
  tilt = schema.default(schema.number())(math.pi / 6),
}
local descriptor = schema.object {
  placement = schema.default(placement)(placement.parse {}),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

local function checkRemovedFields(value: unknown, name: string?): ()
  if type(value) ~= 'table' then
    return
  end
  local fields = value :: { [string]: unknown }
  for _, field in { 'hand', 'size', 'offset', 'haptic' } do
    if rawget(fields, field) ~= nil then
      local prefix = if name then 'plugin ' .. name .. ': ' else ''
      error(prefix .. 'wristKeyboard.' .. field .. ' is removed; configure settings.menu instead', 0)
    end
  end
end

-- Keep the descriptor token and witnesses so configured providers retain the placement schema metadata.
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
