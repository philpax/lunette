-- Frame attachments retain detached, validated header outline appearance.

local schema = require '@lunette-plugin/schema'
local vocabulary = require '@lunette-contracts/vocabulary'
local descriptors = require '@lunette-plugins/theme/descriptors'

local frameStyle = {}
local nonnegative = schema.number { minimum = 0 }
local descriptor = schema.object {
  headerHeight = schema.number { positive = true },
  headerRadius = nonnegative,
  borderThickness = nonnegative,
  borderDepth = nonnegative,
  borderColor = descriptors.color,
}

function frameStyle.validate(value: vocabulary.FrameStyle): vocabulary.FrameStyle
  return descriptor.parse(value, 'theme frame style')
end

frameStyle.equal = descriptors.equal :: (vocabulary.FrameStyle, vocabulary.FrameStyle) -> boolean

return frameStyle
