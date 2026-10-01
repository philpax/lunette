-- The key bindings provider: a broker for desktop key chords.
--
-- Each activation keeps its own registrations, keyed by chord. A registration
-- belongs to the owner that made it and ends with that owner. The provider
-- takes every desktop key press in the frame provider's binding phase, with
-- the modifiers LÖVR reports held, and a press a binding matches goes no
-- further, so nothing that delivers keys needs to know about bindings.
-- dispatch is for any other source of presses, such as an on-screen keyboard.
-- The provider takes no options.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/bindings'
local frame = require '@lunette-contracts/frame'
local keys = require '@lunette-contracts/keys'
local protected = require '@lunette-plugins/protected'

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

-- Validation raises without a position; register raises it again at its
-- caller.
local function fail(message: string): never
  error('bindings register: ' .. message, 0)
end

local function rejectUnknown(value: { [unknown]: unknown }, allowed: { [string]: boolean }, fields: string): ()
  for key, _ in value do
    if type(key) ~= 'string' or not allowed[key] then
      fail('unknown field ' .. tostring(key) .. '; the fields are ' .. fields)
    end
  end
end

-- The identity of a chord: its key and its modifiers in a fixed order, so
-- the same chord written with its modifiers in another order is the same.
local function identity(key: string, modifiers: { string }): string
  local sorted = table.clone(modifiers)
  table.sort(sorted, function(first: string, second: string): boolean
    return (KNOWN[first] or 0) < (KNOWN[second] or 0)
  end)
  return key .. '+' .. table.concat(sorted, '+')
end

-- Checks a chord and answers its frozen copy and identity.
local function checked(chord: unknown): (contract.Chord, string)
  if type(chord) ~= 'table' then
    fail('chord is a table of fields, not a ' .. type(chord))
  end
  local raw = chord :: { [unknown]: unknown }
  rejectUnknown(raw, CHORD_KEYS, 'key and modifiers')
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
    register = function(_self: contract.Service, owner: contract.Owner, binding: contract.Binding): plugin.Effect
      local chord: contract.Chord, key: string, run: (contract.Press) -> ()
      local ok, failure = pcall(function(): ()
        if type(binding) ~= 'table' then
          fail('a binding is a table of fields, not a ' .. type(binding))
        end
        rejectUnknown((binding :: unknown) :: { [unknown]: unknown }, BINDING_KEYS, 'chord and run')
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
    -- Answers whether a binding matched, which consumes the press.
    dispatch = function(_self: contract.Service, press: contract.Press): boolean
      local held: { string } = {}
      for _, name in ipairs(press.modifiers) do
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
  defaults = {},
  build = function(context: plugin.Context, _settings: Settings): Service
    return create(context)
  end,
}
