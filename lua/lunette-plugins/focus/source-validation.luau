-- Validates source options and operation metadata before delivery acquires a route.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local keys = require '@lunette-contracts/keys'
local validation = {}

local function integer(value: unknown): boolean
  return type(value) == 'number' and value >= 0 and value < math.huge and value == math.floor(value)
end

function validation.options(options: contract.SourceOptions?): contract.SourceOptions
  local settings: contract.SourceOptions = options or {}
  if type(settings) ~= 'table' or getmetatable(settings) ~= nil then
    error('focus source: options are a plain table', 3)
  end
  plugin.rejectUnknownFields('focus source', settings, { mode = true, nativeTarget = true }, 'mode and nativeTarget', 3)
  if settings.mode ~= nil and settings.mode ~= 'virtual' and settings.mode ~= 'physical' then
    error('focus source: mode is virtual or physical', 3)
  end
  if settings.nativeTarget ~= nil and type(settings.nativeTarget) ~= 'function' then
    error('focus source: nativeTarget is a function', 3)
  end
  return table.freeze(table.clone(settings))
end

function validation.activation(value: contract.Activation): string?
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    return 'the activation is a plain table'
  end
  local known, failure = pcall(function(): ()
    plugin.rejectUnknownFields(
      'focus activation',
      value,
      { code = true, modifiers = true, isRepeat = true, batch = true, physicalModifiers = true },
      'code, modifiers, isRepeat, batch, and physicalModifiers',
      0
    )
  end)
  if not known then
    return tostring(failure)
  end
  if not integer(value.code) then
    return 'the keycode is a finite non-negative evdev code'
  end
  if value.isRepeat ~= nil and type(value.isRepeat) ~= 'boolean' then
    return 'isRepeat is a boolean'
  end
  if value.batch ~= nil and not integer(value.batch) then
    return 'the batch id is a finite non-negative integer'
  end
  if value.physicalModifiers ~= nil then
    local invalid = keys.validatePhysicalModifiers(value.physicalModifiers)
    if invalid then
      return invalid
    end
  end
  local modifiers = value.modifiers
  if modifiers ~= nil then
    if type(modifiers) ~= 'table' or getmetatable(modifiers) ~= nil then
      return 'modifiers are a plain array'
    end
    local count = 0
    for index, name in modifiers do
      if not integer(index) or index < 1 or type(name) ~= 'string' then
        return 'modifiers are a dense array of names'
      end
      count += 1
    end
    for index = 1, count do
      if modifiers[index] == nil then
        return 'modifiers are a dense array of names'
      end
    end
  end
  return nil
end

function validation.batch(id: number): ()
  if not integer(id) then
    error('focus source: batch id is a finite non-negative integer', 3)
  end
end

return validation
