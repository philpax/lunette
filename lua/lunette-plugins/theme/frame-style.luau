-- Frame attachments retain detached, validated header outline appearance.

local schema = require '@lunette-plugin/schema'
local surface = require '@lunette-contracts/surface'

local frameStyle = {}
local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be positive')
end)
local nonnegative = schema.number { minimum = 0 }
local descriptor = schema.object {
  headerHeight = positive,
  headerRadius = nonnegative,
  borderThickness = nonnegative,
  borderDepth = nonnegative,
  borderColor = schema.array(schema.number { minimum = 0, maximum = 1 }, { minLength = 4, maxLength = 4 }),
}

function frameStyle.validate(value: surface.FrameStyle): surface.FrameStyle
  return descriptor.parse(value, 'theme frame style')
end

function frameStyle.equal(a: surface.FrameStyle, b: surface.FrameStyle): boolean
  if
    a.headerHeight ~= b.headerHeight
    or a.headerRadius ~= b.headerRadius
    or a.borderThickness ~= b.borderThickness
    or a.borderDepth ~= b.borderDepth
  then
    return false
  end
  for index = 1, 4 do
    if a.borderColor[index] ~= b.borderColor[index] then
      return false
    end
  end
  return true
end

return frameStyle
