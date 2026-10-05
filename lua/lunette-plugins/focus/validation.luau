-- Target data is copied before registration; callback identities remain private to the owning route.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'

local validation = {}
local NATIVE = { kind = true, seat = true, sink = true }
local LOCAL = { kind = true, receiver = true, keymapSeat = true, wantsKeyboard = true }
local RECEIVER = { key = true, text = true, onFocus = true, onBlur = true }

local function plain(label: string, value: unknown): ()
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    error(label .. ': a plain table is required', 3)
  end
end

function validation.target(target: contract.Target): contract.Target
  plain('focus register', target)
  if target.kind == 'native' then
    plugin.rejectUnknownFields('focus register native', target, NATIVE, 'kind, seat, and sink', 3)
    if target.sink == nil then
      error('focus register native: sink is required', 3)
    end
    if target.sink.domain ~= 'window' and target.sink.domain ~= 'host' then
      error('focus register native: sink domain is window or host', 3)
    end
    local copy: contract.Target = { kind = 'native', seat = target.seat, sink = target.sink }
    return table.freeze(copy)
  elseif target.kind == 'local' then
    plugin.rejectUnknownFields(
      'focus register local',
      target,
      LOCAL,
      'kind, receiver, keymapSeat, and wantsKeyboard',
      3
    )
    plain('focus register receiver', target.receiver)
    plugin.rejectUnknownFields(
      'focus register receiver',
      target.receiver,
      RECEIVER,
      'key, text, onFocus, and onBlur',
      3
    )
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

return validation
