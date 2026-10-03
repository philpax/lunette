local rules = require '@lunette-contracts/rules'
local a: rules.Match = {
  width = function(value: string): boolean
    return value == ''
  end,
} -- reject.
local b: rules.Match = {
  appId = function(value: number): boolean
    return value == 1
  end,
} -- reject.
local c: rules.Match = {
  opaque = function(): string
    return 'yes'
  end,
} -- reject.
local d: rules.Properties = {
  width = function(): string
    return 'wide'
  end,
} -- reject.
local e: rules.Evaluators = { custom = 42 } -- reject.
return { a, b, c, d, e }
