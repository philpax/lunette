-- Stores owner-scoped menu actions without rendering or selecting desktop policy.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/menu'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local listeners = require '@lunette-plugins/registration/listeners'
local snapshot = require '@self/private/snapshot'

export type Config = {}
export type Settings = {}
export type Service = contract.Service

type Entry = {
  owner: contract.Owner,
  action: snapshot.Metadata,
  run: (() -> ())?,
  token: contract.Token,
  enabled: boolean,
  selected: boolean,
}

local function create(context: plugin.Context): contract.Service
  local byId: { [string]: Entry } = {}
  local changed = listeners.new<<() -> ()>>(context)

  local function announce(): ()
    changed:each('menu onChanged', function(run: () -> ()): ()
      run()
    end)
  end

  local function live(entry: Entry): boolean
    return context:active() and byId[entry.action.id] == entry and context:owns(entry.owner)
  end

  local function listed(): { contract.Descriptor }
    local result: { contract.Descriptor } = {}
    for _, entry in pairs(byId) do
      if live(entry) then
        local action = entry.action
        result[#result + 1] = {
          id = action.id,
          label = action.label,
          group = action.group,
          order = action.order,
          enabled = entry.enabled,
          selected = entry.selected,
          token = entry.token,
        }
      end
    end
    table.sort(result, function(first: contract.Descriptor, second: contract.Descriptor): boolean
      if first.group ~= second.group then
        return first.group < second.group
      end
      if first.order ~= second.order then
        return first.order < second.order
      end
      return first.id < second.id
    end)
    return result
  end

  return {
    register = function(_self: contract.Service, owner: contract.Owner, action: contract.Action): contract.Registration
      if not context:active() then
        error('menu register: the provider is inactive', 2)
      end
      context:checkOwner(owner)
      local captured, run = snapshot.action(action)
      local id = captured.id
      local entry: Entry = {
        owner = owner,
        action = captured,
        run = run,
        token = table.freeze { kind = 'menu-token' } :: contract.Token,
        enabled = captured.enabled,
        selected = captured.selected,
      }
      -- An owner fails ownership checks while the runtime releases one of its effects, so an explicit dispose announces
      -- after the release returns.
      local disposing = false
      local acquired = context:acquire(owner, function(): () -> ()
        if byId[id] then
          error('menu register: ' .. id .. ' is already registered', 0)
        end
        byId[id] = entry
        return function(): ()
          entry.run = nil
          if byId[id] == entry then
            byId[id] = nil
            if not disposing then
              announce()
            end
          end
        end
      end)
      announce()
      return table.freeze {
        update = function(_registration: contract.Registration, state: contract.State): boolean
          local captured = snapshot.state(state)
          if not live(entry) then
            return false
          end
          local enabled = if captured.enabled ~= nil then captured.enabled else entry.enabled
          local selected = if captured.selected ~= nil then captured.selected else entry.selected
          if enabled ~= entry.enabled or selected ~= entry.selected then
            entry.enabled, entry.selected = enabled, selected
            announce()
          end
          return true
        end,
        dispose = function(_registration: contract.Registration): ()
          disposing = true
          local disposed, failure = pcall(acquired.dispose, acquired)
          disposing = false
          announce()
          if not disposed then
            error(failure, 0)
          end
        end,
      }
    end,
    onChanged = function(_self: contract.Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      context:checkOwner(owner)
      listeners.check('menu onChanged', listener)
      return changed:add(owner, listener.run)
    end,
    list = function(_self: contract.Service): { read [number]: contract.Descriptor }
      return listed()
    end,
    invoke = function(_self: contract.Service, id: string, expected: contract.Token?): contract.Result
      local checked = snapshot.id('invoke', id)
      local entry = byId[checked]
      local run = entry and entry.run
      if
        not entry
        or not run
        or not live(entry)
        or not entry.enabled
        or (expected ~= nil and not rawequal(expected, entry.token))
      then
        return { kind = 'unavailable' }
      end
      local label = 'menu invoke: ' .. checked .. ' owned by ' .. plugin.ownerLabel(entry.owner)
      if not protected.call(label, run) then
        return { kind = 'failed', message = label .. ': the action callback raised an error' }
      end
      return { kind = 'invoked' }
    end,
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result = changed:inspect 'menu.onChanged'
      for _, row in ipairs(listed()) do
        local entry = byId[row.id]
        result[#result + 1] = inspection.registration('handler', 'menu.register', entry.owner, row.id, true, {
          label = row.label,
          group = row.group,
          order = row.order,
          enabled = row.enabled,
          selected = row.selected,
        })
      end
      return inspection.snapshot(result)
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'menu',
  capability = contract.capability,
  build = create,
}
