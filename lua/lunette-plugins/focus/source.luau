-- A source snapshots one route per operation and owns native inverses and physical text-batch eligibility.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local protected = require '@lunette-plugins/protected'
local native = require './source-native'
local validation = require './validation'
local keys = require '@lunette-contracts/keys'

local sources = {}

export type Snapshot = {
  read handle: contract.TargetHandle?,
  read target: contract.Target?,
  read revision: number,
  read owner: contract.Owner?,
}
export type Routing = {
  read snapshot: () -> Snapshot,
  read keymapSeat: () -> lunette.Seat?,
  read dispose: () -> (),
  read blocked: () -> contract.Result?,
}

type Batch = { id: number, revision: number, poisoned: boolean }
type MutableSource = {
  dead: boolean,
  key: (contract.Source, contract.Activation) -> contract.Result,
  text: (contract.Source, string, number?) -> contract.Result,
  keymapSeat: (contract.Source) -> lunette.Seat?,
  beginBatch: (contract.Source, number) -> (),
  reset: (contract.Source) -> boolean,
  destroy: (contract.Source) -> boolean,
}
local CONSUMED, UNHANDLED, refused, failed = native.CONSUMED, native.UNHANDLED, native.refused, native.failed

local function scalars(value: string): { string }?
  if utf8.len(value) == nil then
    return nil
  end
  local result = {}
  for _, scalar in utf8.codes(value) do
    result[#result + 1] = utf8.char(scalar)
  end
  return result
end

local function printable(value: string): boolean
  if utf8.len(value) ~= 1 then
    return false
  end
  local scalar = utf8.codepoint(value)
  return scalar >= 0x20 and (scalar < 0x7f or scalar > 0x9f)
end

function sources.new(
  context: plugin.Context,
  owner: contract.Owner,
  options: contract.SourceOptions?,
  routing: Routing
): (contract.Source, () -> ())
  local mode: 'virtual' | 'physical' = validation.options(options).mode or 'virtual'
  local currentRouting: Routing? = routing
  local sourceLabel = 'focus: source owner ' .. plugin.ownerLabel(owner)
  local driver = native.new(sourceLabel)
  local dead, busy = false, false
  local generation = 0
  local batch: Batch? = nil
  local source: MutableSource

  local function alive(): boolean
    return not dead and context:owns(owner)
  end

  local function valid(snapshot: Snapshot, token: number): boolean
    if not alive() or generation ~= token or (snapshot.handle ~= nil and snapshot.handle.dead) then
      return false
    end
    local route = currentRouting
    if route == nil then
      return false
    end
    local now = route.snapshot()
    if route.blocked() then
      return false
    end
    return generation == token
      and now.revision == snapshot.revision
      and now.handle == snapshot.handle
      and now.target == snapshot.target
  end

  local function reset(): boolean
    generation += 1
    if batch then
      batch.poisoned = true
    end
    return driver.reset()
  end

  local function receiverLabel(snapshot: Snapshot, operation: string): string
    return 'focus: receiver '
      .. plugin.ownerLabel(snapshot.owner or owner)
      .. ': '
      .. operation
      .. ' (source owner '
      .. plugin.ownerLabel(owner)
      .. ')'
  end

  local function localText(snapshot: Snapshot, value: string): contract.Result
    local target = snapshot.target
    if target == nil or target.kind ~= 'local' then
      return refused 'the selected route is not a local receiver'
    end
    local accepted = false
    if
      not protected.call(receiverLabel(snapshot, 'text'), function(): ()
        accepted = target.receiver.text(value)
      end)
    then
      return failed 'the receiver text callback raised; see the reported callback error'
    end
    return if accepted then CONSUMED else UNHANDLED
  end

  local function nativeTarget(
    snapshot: Snapshot,
    forText: boolean
  ): { seat: lunette.Seat?, sink: lunette.Sink, keymapSeat: lunette.Seat? }?
    local target = snapshot.target
    if target == nil or target.kind ~= 'native' or target.sink.dead then
      return nil
    end
    local seat = target.seat
    if seat ~= nil and seat.dead then
      return nil
    end
    local keymapSeat = seat
    if forText and keymapSeat == nil then
      keymapSeat = lunette.defaultSeat()
    end
    return { sink = target.sink, seat = seat, keymapSeat = keymapSeat }
  end

  local function key(snapshot: Snapshot, activation: contract.Activation, token: number): contract.Result
    local target = snapshot.target
    if target == nil then
      return UNHANDLED
    end
    local modifiers: { string } = {}
    local requested = activation.modifiers
    if requested then
      for index = 1, #requested do
        modifiers[index] = requested[index]
      end
    end
    if mode == 'physical' and activation.physicalModifiers then
      modifiers = keys.physicalActivationModifiers(activation.physicalModifiers, modifiers)
    end
    if target.kind == 'native' then
      if mode == 'physical' then
        local policy = keys.physicalNativePolicy(activation.code, modifiers, activation.physicalModifiers)
        if policy == 'unavailable' then
          return refused 'the physical keypad modifier snapshot is unavailable'
        elseif policy == 'text' then
          return UNHANDLED
        end
      end
      local selected = nativeTarget(snapshot, false)
      if selected == nil then
        return refused 'the native target is unavailable'
      end
      return driver.key(selected, activation.code, modifiers, function(): boolean
        return valid(snapshot, token)
      end)
    end
    local accepted = false
    local event: contract.KeyEvent = table.freeze {
      code = activation.code,
      modifiers = table.freeze(table.clone(modifiers)),
      source = mode,
      isRepeat = activation.isRepeat == true,
    }
    if
      not protected.call(receiverLabel(snapshot, 'key'), function(): ()
        accepted = target.receiver.key(event)
      end)
    then
      return failed 'the receiver key callback raised; see the reported callback error'
    end
    if accepted then
      return CONSUMED
    end
    if not valid(snapshot, token) then
      return refused 'the key route changed during receiver delivery'
    end
    if mode == 'physical' or keys.commandChord(modifiers) then
      return UNHANDLED
    end
    local route = currentRouting
    if route == nil then
      return refused 'the source is no longer live'
    end
    local seat = route.keymapSeat()
    if seat == nil or seat.dead then
      return UNHANDLED
    end
    local character: string? = nil
    if
      not protected.call(receiverLabel(snapshot, 'translate key'), function(): ()
        character = seat:characterFor(activation.code, modifiers)
      end)
    then
      return failed 'translating the key raised; see the reported callback error'
    end
    if not valid(snapshot, token) then
      return refused 'the key route changed while translating text'
    end
    local translated = character
    if translated == nil or not printable(translated) then
      return UNHANDLED
    end
    return localText(snapshot, translated)
  end

  local function text(snapshot: Snapshot, value: string, characters: { string }, token: number): contract.Result
    local target = snapshot.target
    if target == nil then
      return UNHANDLED
    end
    if target.kind == 'local' then
      return localText(snapshot, value)
    end
    local selected = nativeTarget(snapshot, true)
    if selected == nil then
      return refused 'the native target is unavailable'
    end
    return driver.text(selected, value, characters, function(): boolean
      return valid(snapshot, token)
    end)
  end

  local function batchMatches(id: number?, snapshot: Snapshot): boolean
    local current = batch
    return current ~= nil and id == current.id and not current.poisoned and current.revision == snapshot.revision
  end

  local function deliver(operation: (Snapshot, number) -> contract.Result): contract.Result
    if not alive() then
      return refused 'the source owner is no longer live'
    end
    if busy then
      return refused 'the source is already delivering an operation'
    end
    local unsafe = driver.blocked()
    if unsafe then
      return unsafe
    end
    busy = true
    local result: contract.Result = UNHANDLED
    local ok = protected.call(sourceLabel .. ': delivery', function(): ()
      local route = currentRouting
      if route == nil then
        result = refused 'the source is no longer live'
        return
      end
      local refusal = route.blocked()
      if refusal then
        result = refusal
        return
      end
      local snapshot = route.snapshot()
      local token = generation
      if valid(snapshot, token) then
        result = operation(snapshot, token)
      else
        result = refused 'the selected route is no longer live'
      end
    end)
    busy = false
    if not ok then
      reset()
      return failed 'source delivery raised; see the reported callback error'
    end
    return result
  end

  local function destroy(notifyProvider: boolean): boolean
    if dead then
      return false
    end
    local release = if notifyProvider and currentRouting then currentRouting.dispose else nil
    dead, source.dead = true, true
    generation += 1
    batch, currentRouting = nil, nil
    local cleaned = driver.reset()
    if release then
      if not protected.call(sourceLabel .. ': release provider registration', release) then
        cleaned = false
      end
    end
    return cleaned
  end

  source = {
    dead = false,
    key = function(_self: contract.Source, activation: contract.Activation): contract.Result
      local invalid = validation.activation(activation)
      if invalid then
        return refused(invalid)
      end
      local operation: contract.Activation = table.freeze {
        code = activation.code,
        modifiers = if activation.modifiers then table.freeze(table.clone(activation.modifiers)) else nil,
        physicalModifiers = if activation.physicalModifiers
          then keys.snapshotPhysicalModifiers(activation.physicalModifiers)
          else nil,
        isRepeat = activation.isRepeat,
        batch = activation.batch,
      }
      return deliver(function(snapshot: Snapshot, token: number): contract.Result
        if mode == 'physical' and operation.batch ~= nil then
          local current = batch
          if current == nil or operation.batch ~= current.id or snapshot.revision ~= current.revision then
            return refused 'the physical key batch is stale'
          end
        end
        local current = batch
        local result = key(snapshot, operation, token)
        local target = snapshot.target
        if mode == 'physical' and current and target and target.kind == 'local' and result.kind ~= 'unhandled' then
          current.poisoned = true
        end
        return result
      end)
    end,
    text = function(_self: contract.Source, value: string, id: number?): contract.Result
      local characters = scalars(value)
      if characters == nil then
        return refused 'text is not valid UTF-8'
      end
      return deliver(function(snapshot: Snapshot, token: number): contract.Result
        if mode == 'physical' and not batchMatches(id, snapshot) then
          return refused 'the physical text batch is stale or poisoned'
        end
        return text(snapshot, value, characters, token)
      end)
    end,
    keymapSeat = function(_self: contract.Source): lunette.Seat?
      if not alive() then
        return nil
      end
      local route = currentRouting
      local seat = if route then route.keymapSeat() else nil
      return if seat and not seat.dead then seat else nil
    end,
    beginBatch = function(_self: contract.Source, id: number): ()
      validation.batch(id)
      if mode ~= 'physical' or not alive() or (batch ~= nil and batch.id == id) then
        return
      end
      local route = currentRouting
      if route then
        local snapshot = route.snapshot()
        batch = { id = id, revision = snapshot.revision, poisoned = false }
      end
    end,
    reset = function(_self: contract.Source): boolean
      return reset()
    end,
    destroy = function(_self: contract.Source): boolean
      return destroy(true)
    end,
  }
  return source,
    function(): ()
      if not dead then
        local cleaned = destroy(false)
        if not cleaned then
          error('focus source cleanup: native state could not be released', 0)
        end
      end
    end
end

return sources
