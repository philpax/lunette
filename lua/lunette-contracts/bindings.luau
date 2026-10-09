-- The key bindings service contract: a broker for desktop key chords. The provider takes key presses before
-- delivery, and a matched press goes no further, repeats included. A chord has one owner-scoped registration.
-- See docs/dev/lua-api.md#bindings.

local plugin = require '@lunette-plugin'

local bindings = {}

export type Owner = plugin.Owner

export type Chord = {
  read key: KeyCode,
  read modifiers: { read [number]: string }?,
}

-- A press as a binding receives it: the key, every modifier held, and whether it is a repeat.
export type Press = {
  read key: KeyCode,
  read modifiers: { read [number]: string },
  read isRepeat: boolean,
}

export type Binding = {
  read chord: Chord,
  read run: (Press) -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read register: (Service, Owner, Binding) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

-- The modifiers a chord names, as the desktop keyboard holds them.
bindings.MODIFIERS = table.freeze { 'control', 'alt', 'logo', 'shift' } :: { string }

bindings.capability = plugin.capability<<Service>> { name = 'lunette/bindings', schema = 1 }

return bindings
