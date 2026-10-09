-- Resolves the last live owner selection and caches one face per font specification.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/theme'
local inspection = require '@lunette-contracts/inspection'
local descriptors = require '@lunette-plugins/theme/descriptors'
local base = require '@lunette-plugins/theme/base'
local listeners = require '@lunette-plugins/listeners'

export type Service = contract.Service

type Selection = {
  owner: contract.Owner,
  theme: contract.Theme,
  live: boolean,
}

local function build(context: plugin.Context, _settings: {}): Service
  local changed = listeners.new<<(contract.Snapshot) -> ()>>(context)
  local selections: { Selection } = {}
  -- Faces are never released explicitly: LÖVR frees them when collected, and recorded passes hold their own references.
  local faces: { [string]: Font } = {}
  local current: contract.Snapshot = table.freeze { revision = 0, theme = base }
  local open = true
  local draining = false
  local pending = false
  local disposing = false

  local function notify(): ()
    if draining or not open or not context:active() then
      return
    end
    draining = true
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
    if not ok then
      error(failure, 0)
    end
  end

  local function publish(): ()
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
    -- An explicit inverse revokes owner authority while it runs, so delivery waits for the dispose to return.
    if not disposing then
      notify()
    end
  end

  local function face(spec: contract.FontSpec): Font
    local key = descriptors.fontKey(spec)
    local cached = faces[key]
    if cached then
      return cached
    end
    local created = if spec.kind == 'default'
      then lovr.graphics.getDefaultFont()
      else lovr.graphics.newFont(spec.file, spec.size, spec.spread)
    faces[key] = created
    return created
  end

  context:effect(function(): () -> ()
    return function(): ()
      open = false
      pending = false
      changed:clear()
      current = table.freeze { revision = current.revision, theme = base }
      for _, entry in selections do
        entry.live = false
      end
      table.clear(selections)
      table.clear(faces)
    end
  end)

  return {
    current = function(_self: Service): contract.Snapshot
      return current
    end,
    font = function(_self: Service, spec: contract.FontSpec?): Font
      return face(descriptors.font.parse(if spec == nil then current.theme.typography.font else spec, 'theme font'))
    end,
    select = function(_self: Service, owner: contract.Owner, overrides: contract.ThemeOverrides): contract.Registration
      context:checkOwner(owner)
      local captured = descriptors.overrides.parse(overrides, 'theme select')
      local resolved = descriptors.resolve(base, captured)
      face(resolved.typography.font)
      local entry: Selection = { owner = owner, theme = resolved, live = true }
      local effect = context:acquireDeferred(owner, function(): () -> ()
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
          publish()
        end
      end)
      local registration: contract.Registration = table.freeze {
        update = function(_registration: contract.Registration, value: contract.ThemeOverrides): ()
          assert(entry.live and context:owns(owner), 'theme selection update: the registration is disposed')
          local validated = descriptors.overrides.parse(value, 'theme selection update')
          local replacement = descriptors.resolve(base, validated)
          face(replacement.typography.font)
          entry.theme = replacement
          publish()
        end,
        dispose = function(_registration: contract.Registration): ()
          disposing = true
          local disposed, failure = pcall(effect.dispose, effect)
          disposing = false
          notify()
          if not disposed then
            error(failure, 0)
          end
        end,
      }
      publish()
      return registration
    end,
    onChanged = function(_self: Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      context:checkOwner(owner)
      plugin.rejectUnknownFields('theme onChanged', listener, { 'run' }, 2)
      if type(listener.run) ~= 'function' then
        error('theme onChanged: run is a function, not a ' .. type(listener.run), 2)
      end
      return changed:add(owner, listener.run)
    end,
    inspect = function(_self: Service): inspection.Snapshot
      local result = changed:inspect 'theme.onChanged'
      for index, entry in selections do
        result[#result + 1] = inspection.registration('selection', 'theme.select', entry.owner, nil, entry.live, {
          rank = index,
          selected = index == #selections,
          font = descriptors.fontKey(entry.theme.typography.font),
        })
      end
      return inspection.snapshot(result, { revision = current.revision })
    end,
  }
end

return plugin.provider<<{}, {}, Service>> {
  name = 'theme',
  capability = contract.capability,
  build = build,
}
