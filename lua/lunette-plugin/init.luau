-- The typed facade declares plugin contracts and validates them at runtime.

local native = require '@lunette'
local adapter = require '@lunette-plugin/adapter'
local compose = require '@lunette-plugin/compose'
local options = require '@lunette-plugin/options'
local provider = require '@lunette-plugin/provider'
local consumer = require '@lunette-plugin/consumer'
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
export type ProviderSpec<C, S, T> = provider.Spec<C, S, T>
export type Provider<C, T> = provider.Provider<C, T>
export type ConsumerSpec<C, S> = consumer.Spec<C, S>
export type Consumer<C> = consumer.Consumer<C>
export type Entry = compose.Entry
export type Patch = compose.Patch
export type PluginContractToken = native.PluginContractToken
export type PluginContext = native.PluginContext
export type PluginEffect = native.PluginEffect
export type PluginDefinition = native.PluginDefinition
export type PluginRuntime = native.PluginRuntime
export type PluginInstance = native.PluginInstance

-- Declares a contract and returns its capability:
-- `plugin.capability<<Service>> { name = ..., schema = 1 }`. The name's authority is not authenticated.
function plugin.capability<T>(spec: CapabilitySpec): Capability<T>
  return adapter.capability<<T>>(spec)
end

-- Defines a plugin from its name, the capabilities it requires and provides, and its initializer, whose
-- configuration parameter type is the configuration type.
function plugin.define<C>(spec: Spec<C>): Definition<C>
  return adapter.define(spec)
end

plugin.schema = schema

function plugin.runtime(): Runtime
  return adapter.runtime()
end

-- Raises for a value that is not a table, or for its first key outside `allowed`:
-- `<prefix>: unknown field <key>; the fields are <fields>`. `level` counts as `error`'s does from the
-- function that calls this one, so 2 names that function's caller, and 0 gives no position.
plugin.rejectUnknownFields = options.rejectUnknownFields

-- Returns registered diagnostic metadata without calling an owner's service or effect methods.
plugin.ownerLabel = adapter.ownerLabel

-- Raises unless the option is a native vector with finite x, y, and z components.
function plugin.checkVector(name: string, option: string, value: unknown): ()
  options.checkVector(name, option, value)
end

-- Makes a provider module, `{ definition, define, build, requires }`. The configuration type, the resolved
-- settings type, and the service type are named by explicit instantiation:
-- `plugin.provider<<Config, Settings, Service>> { ... }`.
function plugin.provider<C, S, T>(spec: ProviderSpec<C, S, T>): Provider<C, T>
  return provider.create<<C, S, T>>(spec)
end

-- Makes a consumer module with configured definitions; initialization receives resolved settings.
function plugin.consumer<C, S>(spec: ConsumerSpec<C, S>): Consumer<C>
  return consumer.create<<C, S>>(spec)
end

-- Answers the entries with the patches applied, frozen, defining and enabling nothing. It raises with the id
-- for a malformed entry or patch, a duplicate id, a patch naming no entry, or conflicting patches.
function plugin.compose(entries: { Entry }, patches: { Patch }?): { Entry }
  return compose.apply(entries, patches)
end

-- Answers a function making the patch that configures the entry `id`:
-- `plugin.configure('laser', laser.definition) { style = ... }`. The definition or factory only supplies the
-- configuration type, which a plain patch's `config` lacks, and a factory is not called.
function plugin.configure<C>(id: string, target: Definition<C> | () -> Definition<C>): (C) -> Patch
  return compose.configure(id, target)
end

return plugin
