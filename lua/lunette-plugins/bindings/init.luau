-- Matches owner-scoped key chords during the frame provider's binding phase.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/bindings'
local frame = require '@lunette-contracts/frame'
local keys = require '@lunette-contracts/keys'
local protected = require '@lunette-plugins/protected'
local inspection = require '@lunette-contracts/inspection'

type Registration = {
  owner: contract.Owner,
  chord: contract.Chord,
  key: string,
  run: (contract.Press) -> (),
  active: boolean,
}

local BINDING_KEYS: { [string]: boolean } = { chord = true, run = true }
local CHORD_KEYS: { [string]: boolean } = { key = true, modifiers = true }

local KNOWN: { [string]: number } = {}
for index, name in ipairs(contract.MODIFIERS) do
  KNOWN[name] = index
end

local function fail(message: string): never
  error('bindings register: ' .. message, 0)
end

local function copyModifiers(modifiers: { read [number]: string }): { string }
  local copied: { string } = {}
  for index, modifier in modifiers do
    copied[index] = modifier
  end
  return copied
end

-- Modifier order does not change chord identity.
local function identity(key: string, modifiers: { read [number]: string }): string
  local sorted = copyModifiers(modifiers)
  table.sort(sorted, function(first: string, second: string): boolean
    return (KNOWN[first] or 0) < (KNOWN[second] or 0)
  end)
  return key .. '+' .. table.concat(sorted, '+')
end

local function checked(chord: unknown): (contract.Chord, string)
  if type(chord) ~= 'table' then
    fail('chord is a table of fields, not a ' .. type(chord))
  end
  local raw = chord :: { [unknown]: unknown }
  plugin.rejectUnknownFields('bindings register', raw, CHORD_KEYS, 'key and modifiers', 0)
  local key = raw.key
  if type(key) ~= 'string' or key == '' then
    fail('chord.key is a key name, not ' .. tostring(key))
  end
  local given = raw.modifiers
  if given ~= nil and type(given) ~= 'table' then
    fail('chord.modifiers is a list of modifier names, not a ' .. type(given))
  end
  local modifiers: { string } = {}
  local seen: { [string]: boolean } = {}
  for index, name in ipairs((given or {}) :: { unknown }) do
    if type(name) ~= 'string' or not KNOWN[name] then
      fail(
        string.format(
          'chord.modifiers[%d] is one of %s, not %s',
          index,
          table.concat(contract.MODIFIERS, ', '),
          tostring(name)
        )
      )
    end
    local modifier = name :: string
    if seen[modifier] then
      fail('chord.modifiers names ' .. modifier .. ' twice')
    end
    seen[modifier] = true
    modifiers[#modifiers + 1] = modifier
  end
  local copy: contract.Chord = table.freeze { key = key :: KeyCode, modifiers = table.freeze(modifiers) }
  return copy, identity(key :: string, modifiers)
end

local function create(context: plugin.Context): contract.Service
  local registrations: { Registration } = {}
  local byChord: { [string]: Registration } = {}

  local service: contract.Service = {
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, entry in ipairs(registrations) do
        result[#result + 1] = inspection.registration(
          'handler',
          'bindings.register',
          entry.owner,
          entry.key,
          entry.active and context:owns(entry.owner),
          { key = entry.chord.key, modifiers = table.concat(copyModifiers(entry.chord.modifiers or {}), '+') }
        )
      end
      return inspection.snapshot(result)
    end,
    register = function(_self: contract.Service, owner: contract.Owner, binding: contract.Binding): plugin.Effect
      local chord: contract.Chord, key: string, run: (contract.Press) -> ()
      local ok, failure = pcall(function(): ()
        if type(binding) ~= 'table' then
          fail('a binding is a table of fields, not a ' .. type(binding))
        end
        plugin.rejectUnknownFields('bindings register', binding, BINDING_KEYS, 'chord and run', 0)
        chord, key = checked(binding.chord)
        if type(binding.run) ~= 'function' then
          fail('run is a function, not a ' .. type(binding.run))
        end
        run = binding.run
        if byChord[key] then
          fail(key .. ' is already bound')
        end
      end)
      if not ok then
        error(failure, 2)
      end
      local entry: Registration = { owner = owner, chord = chord, key = key, run = run, active = true }
      return context:acquire(owner, function(): () -> ()
        if byChord[key] then
          error('bindings register: ' .. key .. ' is already bound', 0)
        end
        registrations[#registrations + 1] = entry
        byChord[key] = entry
        return function(): ()
          entry.active = false
          if byChord[key] == entry then
            byChord[key] = nil
          end
          local index = table.find(registrations, entry)
          if index then
            table.remove(registrations, index)
          end
        end
      end)
    end,
    -- A matched binding consumes the press, including repeats and callback failures.
    dispatch = function(_self: contract.Service, press: contract.Press): boolean
      local held: { string } = {}
      for index = 1, #press.modifiers do
        local name = press.modifiers[index]
        if KNOWN[name] and not table.find(held, name) then
          held[#held + 1] = name
        end
      end
      local entry = byChord[identity(press.key, held)]
      if not entry or not entry.active or not context:owns(entry.owner) then
        return false
      end
      if press.isRepeat then
        return true
      end
      protected.call('bindings: ' .. entry.key, function(): ()
        entry.run(press)
      end)
      return true
    end,
    chords = function(_self: contract.Service): { contract.Chord }
      local result: { contract.Chord } = {}
      for _, entry in ipairs(registrations) do
        if entry.active then
          result[#result + 1] = entry.chord
        end
      end
      return result
    end,
  }
  local frameService: frame.Service = context:require(frame.capability)
  frameService:onKey(context, {
    phase = 'binding',
    run = function(event: frame.KeyEvent): boolean?
      return service:dispatch {
        key = event.key,
        modifiers = keys.heldModifiers { isDown = lovr.system.isKeyDown, shift = true },
        isRepeat = event.isRepeat,
      }
    end,
  })
  return service
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'bindings',
  capability = contract.capability,
  requires = { frame = frame.capability },
  build = create,
}
