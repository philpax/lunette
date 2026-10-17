-- Validates detached frame appearance and compares its fixed contract fields.

local schema = require '@lunette-plugin/schema'
local vocabulary = require '@lunette-contracts/vocabulary'
local color = require '@lunette-contracts/schemas/color'

local frameStyle = {}
local nonnegative = schema.number { minimum = 0 }
local descriptor = schema.object {
  headerHeight = schema.number { positive = true },
  headerRadius = nonnegative,
  borderThickness = nonnegative,
  borderDepth = nonnegative,
  borderColor = color,
}

function frameStyle.validate(value: vocabulary.FrameStyle): vocabulary.FrameStyle
  return descriptor.parse(value, 'theme frame style')
end

function frameStyle.equal(first: vocabulary.FrameStyle, second: vocabulary.FrameStyle): boolean
  return first.headerHeight == second.headerHeight
    and first.headerRadius == second.headerRadius
    and first.borderThickness == second.borderThickness
    and first.borderDepth == second.borderDepth
    and first.borderColor[1] == second.borderColor[1]
    and first.borderColor[2] == second.borderColor[2]
    and first.borderColor[3] == second.borderColor[3]
    and first.borderColor[4] == second.borderColor[4]
end

return table.freeze(frameStyle)
