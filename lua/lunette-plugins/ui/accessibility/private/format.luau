-- The accessibility settings file: the checks for each setting, over the shared settings file format.

local accessibility = require '@lunette-contracts/accessibility'
local settingsFile = require '@lunette-plugins/storage/settings-file'

local format = {}

format.VERSION = 1

export type File = {
  settings: accessibility.Settings,
  -- Fields of the settings table that this version does not know, kept as read.
  unknown: { [string]: any },
}

export type Loaded =
  { read kind: 'settings', read file: File, read skipped: { string } }
  | { read kind: 'fromTheFuture', read found: number }
  | { read kind: 'broken', read message: string }

type Check = (any) -> boolean

local CHECKS: { [string]: Check } = {
  reducedMotion = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  textScale = function(value: any): boolean
    return type(value) == 'number' and value >= 0.5 and value <= 2
  end,
  highContrast = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  timing = function(value: any): boolean
    return type(value) == 'number' and value >= 0.5 and value <= 5
  end,
  haptics = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  sounds = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  handedness = function(value: any): boolean
    return value == 'left' or value == 'right'
  end,
}

-- The settings file's description for a path in the save directory.
function format.spec(path: string): settingsFile.Spec
  return {
    path = path,
    label = 'accessibility: settings',
    version = format.VERSION,
    checks = CHECKS,
    defaults = accessibility.DEFAULTS :: any,
  }
end

local SPEC = format.spec 'accessibility.settings'

-- Whether a value is valid for a known setting; an unknown name is never valid here.
function format.valid(name: string, value: any): boolean
  return settingsFile.valid(SPEC, name, value)
end

function format.read(text: string): Loaded
  return settingsFile.read(SPEC, text) :: any
end

function format.render(file: File): string
  return settingsFile.render(SPEC, file :: any)
end

return format
