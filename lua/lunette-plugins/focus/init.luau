-- The focus provider: which seat's keyboard goes to which sink. A grant is held by its owner, one per owner
-- and seat, and released as an inverse on that owner, so a failing withdrawal is the owner's failure.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local protected = require '@lunette-plugins/protected'
local holders = require '@lunette-plugins/focus/holders'

type Grant = {
  holder: holders.Holder,
  effect: plugin.Effect?,
}

type Listener = {
  owner: contract.Owner,
  run: (contract.Focus) -> (),
  active: boolean,
}

local FOCUS_KEYS: { [string]: boolean } = { seat = true, sink = true }
local LISTENER_KEYS: { [string]: boolean } = { run = true }

-- The key a grant without a seat is kept under.
local NO_SEAT = table.freeze {}

local function checkFields(operation: string, value: unknown, allowed: { [string]: boolean }, fields: string): ()
  if type(value) ~= 'table' then
    error(string.format('focus %s: the argument is a table of fields, not a %s', operation, type(value)), 3)
  end
  for key, _ in value :: { [unknown]: unknown } do
    if type(key) ~= 'string' or not allowed[key] then
      error(string.format('focus %s: unknown field %s; the fields are %s', operation, tostring(key), fields), 3)
    end
  end
end

local function create(context: plugin.Context): contract.Service
  local state = holders.new()
  local grants: { [contract.Owner]: { [unknown]: Grant } } = {}
  local listeners: { Listener } = {}

  -- Calls every live listener when the answered pair differs from the pair
  -- answered before the change.
  local function announce(seat: lunette.Seat?, sink: lunette.Sink?): ()
    local nowSeat, nowSink = holders.focused(state)
    if nowSeat == seat and nowSink == sink then
      return
    end
    local change: contract.Focus = table.freeze { seat = nowSeat, sink = nowSink }
    for _, entry in ipairs(table.clone(listeners)) do
      if entry.active and context:owns(entry.owner) then
        protected.call('focus: listener', function(): ()
          entry.run(change)
        end)
      end
    end
  end
  local function changing(change: () -> ()): ()
    local seat, sink = holders.focused(state)
    change()
    announce(seat, sink)
  end

  -- Takes back any grants left at the activation's end; owners normally unload first.
  context:effect(function(): () -> ()
    return function(): ()
      table.clear(grants)
      for _, entry in ipairs(listeners) do
        entry.active = false
      end
      table.clear(listeners)
      holders.clear(state)
    end
  end)

  return {
    focused = function(_self: contract.Service): (lunette.Seat?, lunette.Sink?)
      return holders.focused(state)
    end,
    setFocus = function(_self: contract.Service, owner: contract.Owner, target: contract.Focus): plugin.Effect
      checkFields('setFocus', target, FOCUS_KEYS, 'seat and sink')
      local seat, sink = target.seat, target.sink
      local key: unknown = seat or NO_SEAT
      local owned = grants[owner]
      local existing = owned and owned[key]
      local effect = existing and existing.effect
      if existing and effect then
        context:checkOwner(owner)
        changing(function(): ()
          holders.grant(state, existing.holder, seat, sink)
        end)
        return effect
      end
      local entry: Grant = { holder = holders.holder(), effect = nil }
      local acquired = context:acquire(owner, function(): () -> ()
        changing(function(): ()
          holders.grant(state, entry.holder, seat, sink)
        end)
        local current = grants[owner] or {}
        grants[owner] = current
        current[key] = entry
        return function(): ()
          local remaining = grants[owner]
          if remaining and remaining[key] == entry then
            remaining[key] = nil
            if next(remaining) == nil then
              grants[owner] = nil
            end
          end
          changing(function(): ()
            holders.revoke(state, entry.holder)
          end)
        end
      end)
      entry.effect = acquired
      return acquired
    end,
    onChanged = function(_self: contract.Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      checkFields('onChanged', listener, LISTENER_KEYS, 'run')
      local run = listener.run
      if type(run) ~= 'function' then
        error('focus onChanged: run is a function, not a ' .. type(run), 2)
      end
      local entry: Listener = { owner = owner, run = run, active = true }
      return context:acquire(owner, function(): () -> ()
        listeners[#listeners + 1] = entry
        return function(): ()
          entry.active = false
          local index = table.find(listeners, entry)
          if index then
            table.remove(listeners, index)
          end
        end
      end)
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'focus',
  capability = contract.capability,
  defaults = {},
  build = function(context: plugin.Context, _settings: Settings): Service
    return create(context)
  end,
}
