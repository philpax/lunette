-- Resolves the last live owner selection and retains fonts through leases and callback unwind.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/theme'
local inspection = require '@lunette-contracts/inspection'
local descriptors = require '@lunette-plugins/theme/descriptors'
local base = require '@lunette-plugins/theme/base'
local fonts = require '@lunette-plugins/theme/font-pool'
local listeners = require '@lunette-plugins/listeners'

export type Service = contract.Service

type Selection = {
  owner: contract.Owner,
  theme: contract.Theme,
  face: fonts.Record,
  live: boolean,
  explicitDisposal: boolean,
}
type Lease = {
  owner: contract.Owner,
  face: fonts.Record,
  live: boolean,
  invocations: number,
}

local function build(context: plugin.Context, _settings: {}): Service
  local pool = fonts.new()
  local changed = listeners.new<<(contract.Snapshot) -> ()>>(context)
  local selections: { Selection } = {}
  local leases: { [Lease]: boolean } = {}
  local current: contract.Snapshot = table.freeze { revision = 0, theme = base }
  local open = true
  local draining = false
  local pending = false

  local function checkActive(operation: string): ()
    assert(open and context:active(), 'theme ' .. operation .. ': the provider is inactive')
  end

  local function notify(): ()
    if draining or not open or not context:active() then
      return
    end
    draining = true
    pool:defer(true)
    local ok, failure = pcall(function(): ()
      while pending and open and context:active() do
        pending = false
        local event = current
        changed:each('theme onChanged', function(run: (contract.Snapshot) -> ()): ()
          run(event)
        end)
      end
    end)
    draining = false
    local reclaimed, reclaimFailure = pcall(pool.defer, pool, false)
    if not ok then
      error(failure, 0)
    end
    if not reclaimed then
      error(reclaimFailure, 0)
    end
  end

  local function publish(deliver: boolean?): ()
    local resolved = base
    for index = #selections, 1, -1 do
      local entry = selections[index]
      if entry.live then
        resolved = entry.theme
        break
      end
    end
    if descriptors.equal(current.theme, resolved) then
      return
    end
    current = table.freeze { revision = current.revision + 1, theme = resolved }
    pending = true
    if deliver ~= false then
      notify()
    end
  end

  local function change(run: () -> ()): ()
    pool:defer(true)
    local ok, failure = pcall(run)
    local reclaimed, reclaimFailure = pcall(function(): ()
      if not draining then
        pool:defer(false)
      end
    end)
    if not ok then
      error(failure, 0)
    end
    if not reclaimed then
      error(reclaimFailure, 0)
    end
  end

  local function forgetLease(entry: Lease): ()
    if not entry.live and entry.invocations == 0 then
      leases[entry] = nil
    end
  end

  context:effect(function(): () -> ()
    return function(): ()
      open = false
      pending = false
      changed:clear()
      current = table.freeze { revision = current.revision, theme = base }
      local failures: { string } = {}
      local function cleanup(run: () -> ()): ()
        local ok, failure = pcall(run)
        if not ok then
          failures[#failures + 1] = tostring(failure)
        end
      end
      -- Dependent owners normally finish first; returned objects remain invalid even on failed cleanup.
      for _, entry in table.clone(selections) do
        if entry.live then
          entry.live = false
          cleanup(function(): ()
            pool:drop(entry.face, 'selection')
          end)
        end
      end
      table.clear(selections)
      for entry in table.clone(leases) do
        if entry.live then
          entry.live = false
          cleanup(function(): ()
            pool:drop(entry.face, 'lease')
          end)
          forgetLease(entry)
        end
      end
      cleanup(function(): ()
        pool:close()
      end)
      if #failures > 0 then
        error('theme shutdown: ' .. table.concat(failures, '; '), 0)
      end
    end
  end)

  return {
    current = function(_self: Service): contract.Snapshot
      checkActive 'current'
      return current
    end,
    getFont = function(_self: Service): Font
      checkActive 'getFont'
      for index = #selections, 1, -1 do
        local entry = selections[index]
        if entry.live then
          return entry.face.font
        end
      end
      return lovr.graphics.getDefaultFont()
    end,
    select = function(_self: Service, owner: contract.Owner, overrides: contract.ThemeOverrides): contract.Registration
      checkActive 'select'
      context:checkOwner(owner)
      local captured = descriptors.overrides.parse(overrides, 'theme select')
      local resolved = descriptors.resolve(base, captured)
      local face = pool:hold(resolved.typography.font, 'selection')
      local entry: Selection = {
        owner = owner,
        theme = resolved,
        face = face,
        live = true,
        explicitDisposal = false,
      }
      local ok, effect = pcall(function(): plugin.Effect
        return context:acquireDeferred(owner, function(): () -> ()
          selections[#selections + 1] = entry
          return function(): ()
            if not entry.live then
              return
            end
            entry.live = false
            local index = table.find(selections, entry)
            if index then
              table.remove(selections, index)
            end
            local function restore(): ()
              pool:drop(entry.face, 'selection')
              publish(not entry.explicitDisposal)
            end
            if entry.explicitDisposal then
              pool:defer(true)
              restore()
            else
              change(restore)
            end
          end
        end)
      end)
      if not ok then
        if entry.live then
          entry.live = false
          local released, releaseFailure = pcall(pool.drop, pool, face, 'selection')
          if not released then
            error(tostring(effect) .. '; theme font cleanup: ' .. tostring(releaseFailure), 0)
          end
        end
        error(effect, 0)
      end
      local registration: contract.Registration = table.freeze {
        update = function(_registration: contract.Registration, value: contract.ThemeOverrides): ()
          checkActive 'selection update'
          assert(entry.live and context:owns(owner), 'theme selection update: the registration is disposed')
          local validated = descriptors.overrides.parse(value, 'theme selection update')
          local replacement = descriptors.resolve(base, validated)
          local acquired = pool:hold(replacement.typography.font, 'selection')
          local previous = entry.face
          entry.theme = replacement
          entry.face = acquired
          change(function(): ()
            pool:drop(previous, 'selection')
            publish()
          end)
        end,
        dispose = function(_registration: contract.Registration): ()
          entry.explicitDisposal = true
          local disposed, failure = pcall(effect.dispose, effect)
          entry.explicitDisposal = false
          -- Explicit inverses temporarily revoke owner authority; delivery follows its restoration.
          local notified, notificationFailure = pcall(notify)
          local reclaimed, reclaimFailure = pcall(function(): ()
            if not draining then
              pool:defer(false)
            end
          end)
          if not disposed then
            error(failure, 0)
          end
          if not notified then
            error(notificationFailure, 0)
          end
          if not reclaimed then
            error(reclaimFailure, 0)
          end
        end,
      }
      publish()
      return registration
    end,
    acquireFont = function(_self: Service, owner: contract.Owner, spec: contract.FontSpec?): contract.FontLease
      checkActive 'acquireFont'
      context:checkOwner(owner)
      local captured =
        descriptors.font.parse(if spec == nil then current.theme.typography.font else spec, 'theme acquireFont')
      local face = pool:hold(captured, 'lease')
      local entry: Lease = { owner = owner, face = face, live = true, invocations = 0 }
      local ok, effect = pcall(function(): plugin.Effect
        return context:acquireDeferred(owner, function(): () -> ()
          leases[entry] = true
          return function(): ()
            if not entry.live then
              return
            end
            entry.live = false
            local released, releaseFailure = pcall(pool.drop, pool, face, 'lease')
            forgetLease(entry)
            if not released then
              error(releaseFailure, 0)
            end
          end
        end)
      end)
      if not ok then
        if entry.live then
          entry.live = false
          local released, releaseFailure = pcall(pool.drop, pool, face, 'lease')
          if not released then
            error(tostring(effect) .. '; theme font cleanup: ' .. tostring(releaseFailure), 0)
          end
        end
        error(effect, 0)
      end
      return table.freeze {
        font = face.font,
        spec = captured,
        withFont = function(_lease: contract.FontLease, run: (Font) -> ()): ()
          checkActive 'withFont'
          assert(entry.live and context:owns(owner), 'theme withFont: the lease is disposed')
          assert(type(run) == 'function', 'theme withFont: the callback must be a function')
          pool:retain(face, 'invocation')
          entry.invocations += 1
          local invoked, failure = pcall(run, face.font)
          entry.invocations -= 1
          local released, releaseFailure = pcall(pool.drop, pool, face, 'invocation')
          forgetLease(entry)
          if not invoked then
            error(failure, 0)
          end
          if not released then
            error(releaseFailure, 0)
          end
        end,
        dispose = function(_lease: contract.FontLease): ()
          effect:dispose()
        end,
      }
    end,
    onChanged = function(_self: Service, owner: contract.Owner, run: (contract.Snapshot) -> ()): plugin.Effect
      checkActive 'onChanged'
      context:checkOwner(owner)
      assert(type(run) == 'function', 'theme onChanged: the callback must be a function')
      return changed:add(owner, run)
    end,
    inspect = function(_self: Service): inspection.Snapshot
      checkActive 'inspect'
      local result = changed:inspect 'theme.onChanged'
      for index, entry in selections do
        result[#result + 1] = inspection.registration('selection', 'theme.select', entry.owner, nil, entry.live, {
          rank = index,
          selected = index == #selections,
          font = descriptors.fontKey(entry.face.spec),
          invocations = entry.face.holds.invocation,
        })
      end
      for entry in leases do
        result[#result + 1] = inspection.registration('hold', 'theme.acquireFont', entry.owner, nil, entry.live, {
          font = descriptors.fontKey(entry.face.spec),
          invocations = entry.invocations,
        })
      end
      return inspection.snapshot(result, { revision = current.revision })
    end,
  }
end

return plugin.provider<<{}, {}, Service>> {
  name = 'theme',
  capability = contract.capability,
  defaults = {},
  build = build,
}
