-- The key bindings service contract: a broker for desktop key chords. The provider takes key presses before
-- delivery, and a matched press goes no further, repeats included. dispatch offers a press from another
-- source, such as an on-screen keyboard. A chord has one owner-scoped registration. See
-- docs/dev/lua-api.md#bindings.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local bindings = {}

export type Owner = owner.Owner

export type Chord = {
  read key: KeyCode,
  read modifiers: { string }?,
}

-- A press as the dispatcher reads it: the key, every modifier held, and
-- whether it is a repeat.
export type Press = {
  read key: KeyCode,
  read modifiers: { string },
  read isRepeat: boolean,
}

export type Binding = {
  read chord: Chord,
  read run: (Press) -> (),
}

export type Service = {
  read register: (Service, Owner, Binding) -> plugin.Effect,
  read dispatch: (Service, Press) -> boolean,
  read chords: (Service) -> { Chord },
}

export type Capability = plugin.Capability<Service>

-- The modifiers a chord names, as the desktop keyboard holds them.
bindings.MODIFIERS = table.freeze { 'control', 'alt', 'logo', 'shift' } :: { string }

bindings.capability = plugin.capability<<Service>> { name = 'lunette/bindings', schema = 1 }

return bindings
