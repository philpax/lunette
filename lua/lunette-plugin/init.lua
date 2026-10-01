-- The typed plugin authoring facade.
--
-- Capability and configuration relationships stay in the public types. The
-- adapter enforces declaration membership and publication at runtime. A
-- contract is declared only through `plugin.capability`, which binds its token
-- to the capability at once, so no unbound token is exported.

local native = require '@lunette'
local adapter = require '@lunette-plugin/adapter'

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

return plugin
