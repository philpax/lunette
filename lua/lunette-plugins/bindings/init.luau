-- Matches owner-scoped key chords during the frame provider's binding phase.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/bindings'
local frame = require '@lunette-contracts/frame'
local protected = require '@lunette-plugins/protected'
local registry = require '@lunette-plugins/registry'
local inspection = require '@lunette-contracts/inspection'

local BINDING_KEYS: { string } = { 'chord', 'run' }
local CHORD_KEYS: { string } = { 'key', 'modifiers' }

-- A chord names only the modifiers that make a command or change its level; locks and AltGr never take part.
local MODIFIERS: { lunette.ModifierName } = { 'control', 'alt', 'logo', 'shift' }
table.freeze(MODIFIERS)

local KNOWN: { [string]: number } = {}
for index, name in ipairs(MODIFIERS) do
  KNOWN[name] = index
end

-- Raises at the level of register's caller. `checked` adds one frame and `fail` another.
local function fail(message: string, level: number): never
  error('bindings register: ' .. message, level + 1)
end

-- Modifier order does not change chord identity.
local function identity(key: string, modifiers: { read [number]: string }): string
  local sorted = table.clone(modifiers) :: { string }
  table.sort(sorted, function(first: string, second: string): boolean
    return (KNOWN[first] or 0) < (KNOWN[second] or 0)
  end)
  return key .. '+' .. table.concat(sorted, '+')
end

local function checked(chord: unknown): (contract.Chord, string, { lunette.ModifierName })
  plugin.rejectUnknownFields('bindings register', chord, CHORD_KEYS, 3)
  local raw = chord :: { [unknown]: unknown }
  local key = raw.key
  if type(key) ~= 'string' or key == '' then
    fail('chord.key is a key name, not ' .. tostring(key), 3)
  end
  local given = raw.modifiers
  if given ~= nil and type(given) ~= 'table' then
    fail('chord.modifiers is a list of modifier names, not a ' .. type(given), 3)
  end
  local modifiers: { lunette.ModifierName } = {}
  local seen: { [string]: boolean } = {}
  for index, name in ipairs((given or {}) :: { unknown }) do
    if type(name) ~= 'string' or not KNOWN[name] then
      fail(
        string.format('chord.modifiers[%d] is one of %s, not %s', index, table.concat(MODIFIERS, ', '), tostring(name)),
        3
      )
    end
    local modifier = name :: lunette.ModifierName
    if seen[modifier] then
      fail('chord.modifiers names ' .. modifier .. ' twice', 3)
    end
    seen[modifier] = true
    modifiers[#modifiers + 1] = modifier
  end
  local copy: contract.Chord = table.freeze { key = key :: KeyCode, modifiers = table.freeze(modifiers) }
  return copy, identity(key :: string, modifiers), modifiers
end

type Bound = {
  chord: contract.Chord,
  run: (contract.Press) -> (),
}

local function create(context: plugin.Context): contract.Service
  local bound = registry.new<<Bound>>(context, 'bindings register')

  -- A matched binding consumes the press, including repeats and callback failures.
  local function dispatch(press: contract.Press): boolean
    local held: { string } = {}
    for index = 1, #press.modifiers do
      local name = press.modifiers[index]
      if KNOWN[name] and not table.find(held, name) then
        held[#held + 1] = name
      end
    end
    local key = identity(press.key, held)
    local entry = bound:get(key)
    if not entry then
      return false
    end
    if press.isRepeat then
      return true
    end
    protected.call('bindings: ' .. key, function(): ()
      entry.run(press)
    end)
    return true
  end

  local service: contract.Service = {
    inspect = function(_self: contract.Service): inspection.Snapshot
      return inspection.snapshot(bound:inspect('handler', 'bindings.register'))
    end,
    register = function(_self: contract.Service, owner: contract.Owner, binding: contract.Binding): plugin.Effect
      plugin.rejectUnknownFields('bindings register', binding, BINDING_KEYS, 2)
      local chord, key, modifiers = checked(binding.chord)
      local run = binding.run
      if type(run) ~= 'function' then
        fail('run is a function, not a ' .. type(run), 2)
      end
      return bound:add(owner, key, { chord = chord, run = run }, {
        key = chord.key,
        modifiers = table.concat(modifiers, '+'),
      })
    end,
  }
  local frameService: frame.Service = context:require(frame.capability)
  frameService:onKey(context, {
    phase = 'binding',
    run = function(event: frame.HostKeyEvent): boolean?
      return dispatch {
        key = event.key,
        modifiers = event.modifiers,
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
  requires = { frame.capability },
  build = create,
}
