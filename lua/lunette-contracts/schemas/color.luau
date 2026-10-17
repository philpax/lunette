-- Validates a colour as four components from 0 to 1: red, green, blue, and alpha.

local schema = require '@lunette-plugin/schema'

return schema.array(schema.number { minimum = 0, maximum = 1 }, { minLength = 4, maxLength = 4 })
