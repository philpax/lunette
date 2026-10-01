-- The key bindings service contract.
--
-- A broker for desktop key chords. A plugin registers a chord and what it
-- runs; whatever reads the desktop keyboard dispatches each key press to the
-- broker before it forwards the key anywhere else, and a press a binding
-- matches goes no further. The shipped desktop/input dispatches in the frame
-- provider's binding phase.
--
-- A registration is owner-scoped: it lasts until the returned effect is
-- disposed or its owner unloads. A chord names one registration, and
-- registering a chord that is registered raises. A built-in binding is
-- replaced by disabling the composition entry that registers it, never by
-- overriding a registration in place.
--
-- A chord matches a press of its key while exactly its modifiers are held.
-- The modifiers are the names in MODIFIERS. A repeated press of a matched
-- chord is consumed and does not run the binding again. run is called under
-- a protected call; its error is reported through lunette.reportError, and
-- the press is still consumed.

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
