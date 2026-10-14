-- Owns the current keyboard route, independent native seat authority, and routed input sources.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local listeners = require '@lunette-plugins/registration/listeners'
local routes = require '@lunette-plugins/focus/routes'
local validation = require '@lunette-plugins/focus/validation'
local source = require '@lunette-plugins/focus/source'

export type Config = {}
export type Settings = {}
export type Service = contract.Service

type Entry = {
  target: contract.Target?,
  owner: contract.Owner,
  handle: contract.TargetHandle,
  effect: plugin.Effect?,
  dead: boolean,
  seatId: number?,
}

local function create(context: plugin.Context): Service
  local state = routes.new()
  local entries: { [contract.TargetHandle]: Entry } = {}
  local sources: { [contract.Source]: contract.Owner } = {}
  local heard = listeners.new<<(contract.Change) -> ()>>(context)
  local recentSeat: lunette.Seat? = nil
  local failed = false
  local stopped = false

  local function live(entry: Entry): boolean
    return not stopped and not entry.dead and context:owns(entry.owner)
  end
  local function current(): Entry?
    local entry = (state.current :: any) :: Entry?
    return if entry and entries[entry.handle] == entry then entry else nil
  end
  local function change(): contract.Change
    local entry = current()
    local target = entry and entry.target
    local value: contract.Change = {
      target = if entry and live(entry) then entry.handle else nil,
      revision = state.revision,
      kind = if target then target.kind else 'none',
      wantsKeyboard = target ~= nil and target.kind == 'local' and target.wantsKeyboard,
    }
    return table.freeze(value)
  end
  local function resetSources(): boolean
    local ok = true
    for input in pairs(table.clone(sources)) do
      if not input:reset() then
        ok = false
      end
    end
    failed = state.failed or not ok
    return ok
  end
  local function notify(previous: Entry?): ()
    local revision = state.revision
    local notification = change()
    local old = previous and previous.target
    if previous and live(previous) and old and old.kind == 'local' and old.receiver.onBlur then
      protected.call('focus: blur ' .. plugin.ownerLabel(previous.owner), function(): ()
        old.receiver.onBlur(notification)
      end)
    end
    if state.revision ~= revision then
      return
    end
    local entry = current()
    local target = entry and entry.target
    if entry and live(entry) and target and target.kind == 'local' and target.receiver.onFocus then
      protected.call('focus: focus ' .. plugin.ownerLabel(entry.owner), function(): ()
        target.receiver.onFocus(notification)
      end)
    end
    if state.revision ~= revision then
      return
    end
    heard:each('focus: listener', function(run: (contract.Change) -> ()): ()
      run(notification)
    end, function(): boolean
      return state.revision == revision
    end)
  end
  local function transition(entry: Entry?, blur: boolean): boolean
    if entry and not blur and not live(entry) then
      return false
    end
    if entry and not blur and state.current == entry then
      return true
    end
    local previous, revision = current(), state.revision
    if not blur and state.failed then
      return false
    end
    if not blur or state.current == entry then
      if not resetSources() and not blur then
        return false
      end
      if state.revision ~= revision or (entry and not blur and not live(entry)) then
        return false
      end
    end
    local sourcesReady = not failed
    local ok, accepted = pcall(function(): boolean
      if entry then
        return if blur then routes.blur(state, entry) else routes.focus(state, entry)
      end
      return false
    end)
    if state.revision ~= revision then
      local target = entry and entry.target
      if entry and not blur and target and target.kind == 'native' then
        recentSeat = target.seat or lunette.defaultSeat()
        entry.seatId = recentSeat and recentSeat.id
      end
      notify(previous)
    end
    if not ok then
      failed = true
      protected.call(
        'focus: transition ' .. (if entry then plugin.ownerLabel(entry.owner) else 'shutdown'),
        function(): ()
          error(accepted, 0)
        end
      )
      return false
    end
    return accepted and sourcesReady
  end

  local function register(owner: contract.Owner, target: contract.Target): contract.TargetHandle
    context:checkOwner(owner)
    local copied = validation.target(target)
    local entry: Entry
    local handle: contract.TargetHandle = setmetatable({}, {
      __index = function(_self: unknown, key: string): unknown
        if key == 'dead' then
          return not live(entry)
        elseif key == 'focus' then
          return function(_self: contract.TargetHandle): boolean
            return transition(entry, false)
          end
        elseif key == 'blur' then
          return function(_self: contract.TargetHandle): boolean
            return if live(entry) then transition(entry, true) else false
          end
        elseif key == 'destroy' then
          return function(_self: contract.TargetHandle): boolean
            if entry.dead then
              return false
            end
            local effect = entry.effect
            if effect then
              effect:dispose()
            end
            return true
          end
        end
        return nil
      end,
      __newindex = function(): ()
        error('focus: target handles are readonly', 2)
      end,
    }) :: contract.TargetHandle
    local registered: Entry =
      { target = copied, owner = owner, handle = handle, effect = nil, dead = false, seatId = nil }
    entry = registered
    entry.effect = context:acquire(owner, function(): () -> ()
      entries[handle] = entry
      return function(): ()
        if entry.dead then
          return
        end
        entry.dead = true
        entry.target = nil
        transition(entry, true)
        entries[handle] = nil
      end
    end)
    return handle
  end

  local function sweep(): ()
    for _, entry in pairs(table.clone(entries)) do
      local target = entry.target
      if target and target.kind == 'native' and (target.sink.dead or (target.seat and target.seat.dead)) then
        transition(entry, true)
      end
    end
  end
  local lossObserver = plugin.consumer<<{}, {}>> {
    name = 'focus/native-loss',
    requires = { frame.capability },
    init = function(observer: plugin.Context, _settings: {}): ()
      local clock: frame.Service = observer:require(frame.capability)
      clock:onUpdate(observer, {
        phase = 'input',
        order = -100,
        run = function(_dt: number): ()
          sweep()
        end,
      })
      clock:onBatch(observer, {
        run = function(_batch: frame.Batch): ()
          sweep()
        end,
      })
    end,
  }
  context:child(lossObserver.definition)

  local function keymapSeat(): lunette.Seat?
    local entry = current()
    local target = entry and entry.target
    if target and target.kind == 'local' and target.keymapSeat and not target.keymapSeat.dead then
      return target.keymapSeat
    end
    if recentSeat and not recentSeat.dead then
      return recentSeat
    end
    for _, seat in ipairs(lunette.seats()) do
      if not seat.dead then
        return seat
      end
    end
    return nil
  end

  context:effect(function(): () -> ()
    return function(): ()
      stopped = true
      heard:clear()
      for input in pairs(table.clone(sources)) do
        input:destroy()
      end
      for _, entry in pairs(table.clone(entries)) do
        entry.dead, entry.target = true, nil
        transition(entry, true)
      end
      table.clear(entries)
    end
  end)

  return {
    register = function(_self: Service, owner: contract.Owner, target: contract.Target): contract.TargetHandle
      return register(owner, target)
    end,
    focused = function(_self: Service): contract.TargetHandle?
      local entry = current()
      if not entry or not live(entry) then
        return nil
      end
      if not routes.current(state) then
        transition(entry, true)
        return nil
      end
      return entry.handle
    end,
    onChanged = function(_self: Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      context:checkOwner(owner)
      listeners.check('focus onChanged', listener)
      return heard:add(owner, listener.run)
    end,
    newSource = function(_self: Service, owner: contract.Owner, options: contract.SourceOptions?): contract.Source
      context:checkOwner(owner)
      local lifetime: plugin.Effect? = nil
      local value, effect = context:resource(owner, function(): (contract.Source, () -> ())
        local made, inverse = source.new(context, owner, options, {
          snapshot = function(): source.Snapshot
            sweep()
            local entry = current()
            return {
              handle = entry and entry.handle,
              target = entry and entry.target,
              owner = entry and entry.owner,
              revision = state.revision,
            }
          end,
          dispose = function(): ()
            local owned = lifetime
            lifetime = nil
            if owned then
              owned:dispose()
            end
          end,
          blocked = function(): contract.Result?
            if state.failed then
              local result: contract.Result = { kind = 'refused', message = 'native focus cleanup is unresolved' }
              return table.freeze(result)
            end
            return nil
          end,
          keymapSeat = keymapSeat,
        })
        sources[made] = owner
        return made,
          function(): ()
            sources[made] = nil
            lifetime = nil
            inverse()
          end
      end)
      lifetime = effect
      return value
    end,
    inspect = function(_self: Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, entry in pairs(entries) do
        local target = entry.target
        result[#result + 1] = inspection.registration('focus', 'focus.register', entry.owner, nil, live(entry), {
          current = state.current == entry,
          kind = if target then target.kind else 'none',
          wantsKeyboard = target ~= nil and target.kind == 'local' and target.wantsKeyboard,
          revision = state.revision,
          seatId = entry.seatId,
        })
      end
      local selected = current()
      local selectedTarget = selected and selected.target
      local seat = keymapSeat()
      for _, registration in ipairs(heard:inspect 'focus.onChanged') do
        result[#result + 1] = registration
      end
      local count = 0
      for _, owner in pairs(sources) do
        count += 1
        result[#result + 1] = inspection.registration('producer', 'focus.newSource', owner, nil, context:owns(owner))
      end
      return inspection.snapshot(result, {
        revision = state.revision,
        sourceCount = count,
        failed = failed or state.failed,
        kind = if selectedTarget then selectedTarget.kind else 'none',
        keymapSeatId = if seat then seat.id else nil,
      }, { 'receiver callbacks are private' })
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'focus',
  capability = contract.capability,
  build = create,
}
