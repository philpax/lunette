-- The typed facade declares plugin contracts and validates them at runtime.

local native = require '@lunette'
local adapter = require '@lunette-plugin/adapter'
local compose = require '@lunette-plugin/compose'
local options = require '@lunette-plugin/options'
local configured = require '@lunette-plugin/configured'
local schema = require '@lunette-plugin/schema'

local plugin = {}

export type Capability<T> = adapter.Capability<T>
export type CapabilitySpec = adapter.CapabilitySpec
export type Effect = adapter.Effect
export type Context = adapter.Context
export type Subscription<E> = adapter.Subscription<E>
export type Owner = adapter.Owner
export type Publisher = adapter.Publisher
export type Declaration = adapter.Declaration
export type Spec<C> = adapter.Spec<C>
export type Definition<C> = adapter.Definition<C>
export type Instance<C> = adapter.Instance<C>
export type Runtime = adapter.Runtime
export type ProviderSpec<C, S, T> = configured.ProviderSpec<C, S, T>
export type Provider<C, T> = configured.Provider<C, T>
export type ConsumerSpec<C, S> = configured.ConsumerSpec<C, S>
export type Consumer<C> = configured.Consumer<C>
export type Entry = compose.Entry
export type Patch = compose.Patch
export type PluginContractToken = native.PluginContractToken
export type PluginContext = native.PluginContext
export type PluginEffect = native.PluginEffect
export type PluginDefinition = native.PluginDefinition
export type PluginRuntime = native.PluginRuntime
export type PluginInstance = native.PluginInstance

-- `plugin.capability<<Service>> { ... }` names the service type. The name is not authenticated.
function plugin.capability<T>(spec: CapabilitySpec): Capability<T>
  return adapter.capability<<T>>(spec)
end

function plugin.define<C>(spec: Spec<C>): Definition<C>
  return adapter.define(spec)
end

plugin.schema = schema

function plugin.runtime(): Runtime
  return adapter.runtime()
end

plugin.rejectUnknownFields = options.rejectUnknownFields

plugin.ownerLabel = adapter.ownerLabel

function plugin.checkVector(name: string, option: string, value: unknown): ()
  options.checkVector(name, option, value)
end

-- Explicit instantiation names the configuration, settings, and service types:
-- `plugin.provider<<Config, Settings, Service>> { ... }`.
function plugin.provider<C, S, T>(spec: ProviderSpec<C, S, T>): Provider<C, T>
  return configured.provider<<C, S, T>>(spec)
end

function plugin.consumer<C, S>(spec: ConsumerSpec<C, S>): Consumer<C>
  return configured.consumer<<C, S>>(spec)
end

-- Applies the patches and freezes the entries without defining or enabling any plugin.
function plugin.compose(entries: { Entry }, patches: { Patch }?): { Entry }
  return compose.apply(entries, patches)
end

-- The target supplies only the configuration type, which a plain patch lacks. A factory is not called.
function plugin.configure<C>(id: string, target: Definition<C> | () -> Definition<C>): (C) -> Patch
  return compose.configure(id, target)
end

return plugin
