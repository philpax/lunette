-- A broker for desktop key chords. The provider takes presses before delivery, and a matched press, repeats
-- included, goes no further.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'

local bindings = {}

export type Owner = plugin.Owner

export type Chord = {
  read key: KeyCode,
  read modifiers: { read [number]: lunette.ModifierName }?,
}

export type Press = {
  read key: KeyCode,
  read modifiers: { read [number]: lunette.ModifierName },
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

bindings.capability = plugin.capability<<Service>> { name = 'lunette/bindings', version = 1 }

return bindings
