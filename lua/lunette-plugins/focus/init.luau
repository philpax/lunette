-- The focus provider: which seat's keyboard goes to which sink. A grant is held by its owner, one per owner
-- and seat, and released as an inverse on that owner, so a failing withdrawal is the owner's failure.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local listeners = require '@lunette-plugins/listeners'
local holders = require '@lunette-plugins/focus/holders'

type Grant = {
  holder: holders.Holder,
  effect: plugin.Effect?,
}

local FOCUS_KEYS: { [string]: boolean } = { seat = true, sink = true }
local LISTENER_KEYS: { [string]: boolean } = { run = true }

-- The key a grant without a seat is kept under.
local NO_SEAT = table.freeze {}

local function create(context: plugin.Context): contract.Service
  local state = holders.new()
  local grants: { [contract.Owner]: { [unknown]: Grant } } = {}
  local heard = listeners.new<<(contract.Focus) -> ()>>(context)

  -- Calls every live listener when the answered pair differs from the pair
  -- answered before the change.
  local function announce(seat: lunette.Seat?, sink: lunette.Sink?): ()
    local nowSeat, nowSink = holders.focused(state)
    if nowSeat == seat and nowSink == sink then
      return
    end
    local change: contract.Focus = table.freeze { seat = nowSeat, sink = nowSink }
    heard:each('focus: listener', function(run: (contract.Focus) -> ()): ()
      run(change)
    end)
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
      heard:clear()
      holders.clear(state)
    end
  end)

  return {
    focused = function(_self: contract.Service): (lunette.Seat?, lunette.Sink?)
      return holders.focused(state)
    end,
    setFocus = function(_self: contract.Service, owner: contract.Owner, target: contract.Focus): plugin.Effect
      plugin.rejectUnknownFields('focus setFocus', target, FOCUS_KEYS, 'seat and sink', 2)
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
      plugin.rejectUnknownFields('focus onChanged', listener, LISTENER_KEYS, 'run', 2)
      local run = listener.run
      if type(run) ~= 'function' then
        error('focus onChanged: run is a function, not a ' .. type(run), 2)
      end
      return heard:add(owner, run)
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'focus',
  capability = contract.capability,
  build = create,
}
