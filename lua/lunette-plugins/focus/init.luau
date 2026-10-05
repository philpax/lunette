-- Each owner's seat focus grant is withdrawn with its owner and reports failures to that owner.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local listeners = require '@lunette-plugins/listeners'
local holders = require '@lunette-plugins/focus/holders'
local inspection = require '@lunette-contracts/inspection'

type Grant = {
  holder: holders.Holder,
  effect: plugin.Effect?,
}

local FOCUS_KEYS: { [string]: boolean } = { seat = true, sink = true }
local LISTENER_KEYS: { [string]: boolean } = { run = true }

local NO_SEAT = table.freeze {}

local function create(context: plugin.Context): contract.Service
  local state = holders.new()
  local grants: { [contract.Owner]: { [unknown]: Grant } } = {}
  local heard = listeners.new<<(contract.Focus) -> ()>>(context)

  -- Announces changes to the live focused seat and sink pair.
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

  -- Releases any grants that remain when the provider activation ends.
  context:effect(function(): () -> ()
    return function(): ()
      table.clear(grants)
      heard:clear()
      holders.clear(state)
    end
  end)

  return {
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result = heard:inspect 'focus.onChanged'
      for owner, owned in pairs(grants) do
        for _, grant in pairs(owned) do
          local holder = grant.holder
          local seat, sink = holder.seat, holder.sink
          local details: { [string]: string | number | boolean } = {
            current = state.current == holder,
            granted = sink ~= nil,
            seatDead = seat ~= nil and seat.dead,
            sinkDead = sink ~= nil and sink.dead,
          }
          if seat then
            details.seatId = seat.id
          end
          result[#result + 1] =
            inspection.registration('focus', 'focus.setFocus', owner, nil, context:owns(owner), details)
        end
      end
      return inspection.snapshot(result, nil, { 'sink identity is not exposed' })
    end,
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

local config = require '@lunette-plugins/focus/config'

export type Config = config.Config
export type Settings = config.Settings
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'focus',
  schema = config,
  capability = contract.capability,
  build = create,
}
