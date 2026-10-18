-- The typed facade declares plugin contracts and validates them at runtime.

local adapter = require '@lunette-plugin/adapter'
local compose = require '@lunette-plugin/compose'
local configured = require '@lunette-plugin/configured'
local fields = require '@lunette-plugin/fields'
local optionalConnection = require '@lunette-plugin/optional-connection'

local plugin = {}

export type Capability<T> = adapter.Capability<T>
export type Effect = adapter.Effect
export type Context = adapter.Context
export type Owner = adapter.Owner
export type Declaration = adapter.Declaration
export type Definition<C> = adapter.Definition<C>
export type Entry = compose.Entry
export type Patch = compose.Patch
export type Connection<T> = optionalConnection.Connection<T>

-- `plugin.capability<<Service>> { ... }` names the service type. The name is not authenticated.
function plugin.capability<T>(spec: adapter.CapabilitySpec): Capability<T>
  return adapter.capability<<T>>(spec)
end

plugin.rejectUnknownFields = fields.rejectUnknownFields

plugin.ownerLabel = adapter.ownerLabel

-- The getter returns a live service and its child owner, or nil while no provider is active.
plugin.connectOptional = optionalConnection.connect

-- Explicit instantiation names the configuration, settings, and service types:
-- `plugin.provider<<Config, Settings, Service>> { ... }`.
function plugin.provider<C, S, T>(spec: configured.ProviderSpec<C, S, T>): configured.Provider<C>
  return configured.provider<<C, S, T>>(spec)
end

function plugin.consumer<C, S>(spec: configured.ConsumerSpec<C, S>): configured.Consumer<C>
  return configured.consumer<<C, S>>(spec)
end

-- Applies the patches and freezes the entries without defining or enabling any plugin.
function plugin.compose(entries: { Entry }, patches: { Patch }?): { Entry }
  return compose.apply(entries, patches)
end

-- The target types the configuration, and composition checks that the entry has it. A factory is not called.
function plugin.configure<C>(id: string, target: Definition<C> | () -> Definition<C>): (C) -> Patch
  return compose.configure(id, target)
end

return plugin
