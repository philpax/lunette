-- Validates registered targets, source options, and operation metadata at the plugin boundary. Target data is
-- copied before registration; callback identities remain private to the owning route.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local keys = require '@lunette-contracts/keys'

local validation = {}
local NATIVE: { string } = { 'kind', 'seat', 'sink' }
local LOCAL: { string } = { 'kind', 'receiver', 'keymapSeat', 'wantsKeyboard' }
local RECEIVER: { string } = { 'key', 'text', 'onFocus', 'onBlur' }
local ACTIVATION: { string } = { 'code', 'modifiers', 'isRepeat', 'batch', 'physicalModifiers' }

local function plain(label: string, value: unknown): ()
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    error(label .. ': a plain table is required', 3)
  end
end

function validation.target(target: contract.Target): contract.Target
  plain('focus register', target)
  if target.kind == 'native' then
    plugin.rejectUnknownFields('focus register native', target, NATIVE, 3)
    if target.sink == nil then
      error('focus register native: sink is required', 3)
    end
    if target.sink.domain ~= 'window' and target.sink.domain ~= 'host' then
      error('focus register native: sink domain is window or host', 3)
    end
    local copy: contract.Target = { kind = 'native', seat = target.seat, sink = target.sink }
    return table.freeze(copy)
  elseif target.kind == 'local' then
    plugin.rejectUnknownFields('focus register local', target, LOCAL, 3)
    plain('focus register receiver', target.receiver)
    plugin.rejectUnknownFields('focus register receiver', target.receiver, RECEIVER, 3)
    if type(target.receiver.key) ~= 'function' or type(target.receiver.text) ~= 'function' then
      error('focus register receiver: key and text are functions', 3)
    end
    if target.receiver.onFocus ~= nil and type(target.receiver.onFocus) ~= 'function' then
      error('focus register receiver: onFocus is an optional function', 3)
    end
    if target.receiver.onBlur ~= nil and type(target.receiver.onBlur) ~= 'function' then
      error('focus register receiver: onBlur is an optional function', 3)
    end
    if type(target.wantsKeyboard) ~= 'boolean' then
      error('focus register local: wantsKeyboard is a boolean', 3)
    end
    local copy: contract.Target = {
      kind = 'local',
      receiver = table.freeze(table.clone(target.receiver)),
      keymapSeat = target.keymapSeat,
      wantsKeyboard = target.wantsKeyboard,
    }
    return table.freeze(copy)
  end
  error('focus register: kind is native or local', 3)
end

local function integer(value: unknown): boolean
  return type(value) == 'number' and value >= 0 and value < math.huge and value == math.floor(value)
end

function validation.options(options: contract.SourceOptions?): contract.SourceOptions
  local settings: contract.SourceOptions = options or {}
  if type(settings) ~= 'table' or getmetatable(settings) ~= nil then
    error('focus source: options are a plain table', 3)
  end
  plugin.rejectUnknownFields('focus source', settings, { 'mode' }, 3)
  if settings.mode ~= nil and settings.mode ~= 'virtual' and settings.mode ~= 'physical' then
    error('focus source: mode is virtual or physical', 3)
  end
  return table.freeze(table.clone(settings))
end

function validation.activation(value: contract.Activation): string?
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    return 'the activation is a plain table'
  end
  local known, failure = pcall(plugin.rejectUnknownFields, 'focus activation', value, ACTIVATION, 0)
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
