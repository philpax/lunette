-- Native mutations retain their original sink and seat until every inverse has been attempted.
local lunette = require '@lunette'
local contract = require '@lunette-contracts/focus'
local protected = require '@lunette-plugins/protected'

local native = {}

type Target = { read seat: lunette.Seat?, read sink: lunette.Sink, read keymapSeat: lunette.Seat? }
type Inverse = { read label: string, read run: () -> boolean }
export type Driver = {
  read key: (Target, number, { string }, () -> boolean) -> contract.Result,
  read text: (Target, string, { string }, () -> boolean) -> contract.Result,
  read reset: () -> boolean,
  read blocked: () -> contract.Result?,
}

type Consumed = { read kind: 'consumed' }
type Refused = { read kind: 'refused', read message: string }
type Failed = { read kind: 'failed', read message: string }
local CONSUMED: Consumed = table.freeze({ kind = 'consumed' } :: Consumed)
local function refused(message: string): Refused
  local result: Refused = { kind = 'refused', message = message }
  return table.freeze(result)
end
local function failed(message: string): Failed
  local result: Failed = { kind = 'failed', message = message }
  return table.freeze(result)
end

function native.new(label: string): Driver
  local pending: { Inverse } = {}
  local cleaning = false
  local unsafe: contract.Result? = nil

  local function invoke(operation: string, run: () -> boolean): contract.Result
    local accepted = false
    if not protected.call(label .. ': ' .. operation, function(): ()
      accepted = run()
    end) then
      return failed(operation .. ' raised; see the reported callback error')
    end
    return if accepted then CONSUMED else refused(operation .. ' was refused')
  end

  local function blocked(): contract.Result?
    if unsafe then
      return unsafe
    end
    if cleaning or #pending > 0 then
      return refused 'native input is already delivering or releasing a stroke'
    end
    return nil
  end

  local function reset(): boolean
    if cleaning then
      return false
    end
    local release = pending
    pending = {}
    cleaning = true
    for index = #release, 1, -1 do
      local inverse = release[index]
      local result = invoke(inverse.label, inverse.run)
      if result.kind ~= 'consumed' and (unsafe == nil or result.kind == 'failed') then
        unsafe = result
      end
    end
    cleaning = false
    return unsafe == nil
  end

  local function live(target: Target): boolean
    return not target.sink.dead and (target.seat == nil or not target.seat.dead)
  end

  local function finish(result: contract.Result): contract.Result
    reset()
    return unsafe or result
  end

  local function key(target: Target, code: number, modifiers: { string }, valid: () -> boolean): contract.Result
    local refusal = blocked()
    if refusal then
      return refusal
    end
    if not valid() or not live(target) then
      return refused 'the native route is no longer live'
    end
    pending[#pending + 1] = {
      label = 'release modifiers',
      run = function(): boolean
        return live(target) and target.sink:modifiers({}, target.seat)
      end,
    }
    local result = invoke('set modifiers', function(): boolean
      return target.sink:modifiers(modifiers, target.seat)
    end)
    if result.kind ~= 'consumed' then
      return finish(result)
    end
    if not valid() or not live(target) or unsafe then
      return finish(refused 'the native route changed while setting modifiers')
    end
    pending[#pending + 1] = {
      label = 'release key',
      run = function(): boolean
        return live(target) and target.sink:key(code, false, target.seat)
      end,
    }
    result = invoke('press key', function(): boolean
      return target.sink:key(code, true, target.seat)
    end)
    if result.kind == 'consumed' and not valid() then
      result = refused 'the native route changed while pressing the key'
    end
    return finish(result)
  end

  local function text(target: Target, value: string, scalars: { string }, valid: () -> boolean): contract.Result
    local refusal = blocked()
    if refusal then
      return refusal
    end
    if not live(target) or not valid() then
      return refused 'the native route is no longer live'
    end
    if target.sink.domain == 'host' then
      local result = invoke('enter text', function(): boolean
        return target.sink:typeText(value, target.seat)
      end)
      return if result.kind == 'consumed' and not valid()
        then refused 'the text route changed during delivery'
        else result
    end
    local seat = target.keymapSeat or target.seat
    if seat == nil or seat.dead then
      return refused 'window text needs a live keymap seat'
    end
    for _, scalar in ipairs(scalars) do
      if not valid() or not live(target) then
        return refused 'the text route changed between characters'
      end
      local stroke: lunette.Stroke? = nil
      if
        not protected.call(label .. ': resolve text stroke', function(): ()
          stroke = seat:strokeFor(scalar)
        end)
      then
        return failed 'resolving a text stroke raised; see the reported callback error'
      end
      if not valid() then
        return refused 'the text route changed while resolving a character'
      end
      local resolved = stroke
      if resolved == nil then
        return refused('the keymap cannot represent character ' .. scalar)
      end
      local result = key(target, resolved.keycode, resolved.modifiers, valid)
      if result.kind ~= 'consumed' then
        return result
      end
    end
    return CONSUMED
  end

  return { key = key, text = text, reset = reset, blocked = blocked }
end

return native
