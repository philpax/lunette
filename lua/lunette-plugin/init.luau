-- The typed plugin authoring facade.
--
-- Capability and configuration relationships stay in the public types. The
-- adapter enforces declaration membership and publication at runtime. A
-- contract is declared only through `plugin.capability`, which binds its token
-- to the capability at once, so no unbound token is exported.

local native = require '@lunette'
local adapter = require '@lunette-plugin/adapter'
local options = require '@lunette-plugin/options'
local provider = require '@lunette-plugin/provider'

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
export type OptionsSpec<S> = options.Spec<S>
export type MergeSpec = options.MergeSpec
export type ProviderSpec<S, T> = provider.Spec<S, T>
export type Provider<C, T> = provider.Provider<C, T>
export type PluginContractToken = native.PluginContractToken
export type PluginContext = native.PluginContext
export type PluginEffect = native.PluginEffect
export type PluginDefinition = native.PluginDefinition
export type PluginRuntime = native.PluginRuntime
export type PluginInstance = native.PluginInstance

-- Declares a contract and returns its capability. The service type is named
-- by explicit instantiation: `plugin.capability<<Service>> { name = ..., schema = 1 }`.
-- The contract name is authority-qualified; the authority is a naming
-- convention and is not authenticated, so a module can declare any
-- authority's contract.
function plugin.capability<T>(spec: CapabilitySpec): Capability<T>
  return adapter.capability<<T>>(spec)
end

-- Defines a plugin from its name, the capabilities it requires and provides,
-- and its initializer. The configuration type is the initializer's annotated
-- configuration parameter type.
function plugin.define<C>(spec: Spec<C>): Definition<C>
  return adapter.define(spec)
end

function plugin.runtime(): Runtime
  return adapter.runtime()
end

-- Answers a plugin's configuration merged over its defaults, copied and
-- frozen, and raises an error naming the plugin and the option for an option
-- the defaults do not name or a value of another type than its default. A
-- record merges key by key; any other value replaces its default.
function plugin.options<S>(spec: OptionsSpec<S>): S
  return options.resolve(spec)
end

-- Answers `over` merged over `base` by the configuration rule, without
-- validating either.
function plugin.merge(spec: MergeSpec): { [string]: unknown }
  return options.merge(spec)
end

-- Makes a provider module, `{ definition, define, build, requires }`, from a
-- builder and its default options. The configuration type, the resolved
-- options type, and the service type are named by explicit instantiation:
-- `plugin.provider<<Config, Settings, Service>> { ... }`.
function plugin.provider<C, S, T>(spec: ProviderSpec<S, T>): Provider<C, T>
  return provider.create<<C, S, T>>(spec)
end

return plugin
