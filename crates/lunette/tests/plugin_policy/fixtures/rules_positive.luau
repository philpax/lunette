local rules = require '@lunette-contracts/rules'
local lunette = require '@lunette'
local match: rules.Match = {
  appId = function(value: string?, window: lunette.Window): boolean
    return value == window.appId
  end,
  title = function(value: string?): boolean
    return value == nil or #value > 0
  end,
  width = function(value: number): boolean
    return value > 0
  end,
  opaque = function(value: boolean): boolean
    return not value
  end,
  contentType = 'video',
}
local properties: rules.Properties = {
  width = function(window: lunette.Window, key: string): number
    return window.width + #key
  end,
  chrome = function(): boolean
    return false
  end,
  callback = function(): string
    return 'literal'
  end,
  evaluate = {
    extension = function(window: lunette.Window, key: string): unknown
      return { window.id, key }
    end,
  },
}
return { match = match, properties = properties }
