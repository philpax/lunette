-- The typed plugin authoring facade.
--
-- Capability and configuration relationships stay in the public types. The
-- adapter enforces declaration membership and publication at runtime.

local native = require '@lunette'
local adapter = require '@lunette-plugin/adapter'

local plugin = {}

export type Capability<T> = adapter.Capability<T>
export type Effect = adapter.Effect
export type Context = adapter.Context
export type Owner = adapter.Owner
export type Publisher = adapter.Publisher
export type Declaration = adapter.Declaration
export type Definition<C> = adapter.Definition<C>
export type Instance<C> = adapter.Instance<C>
export type Runtime = adapter.Runtime
export type PluginContractToken = native.PluginContractToken
export type PluginContext = native.PluginContext
export type PluginEffect = native.PluginEffect
export type PluginDefinition = native.PluginDefinition
export type PluginRuntime = native.PluginRuntime
export type PluginInstance = native.PluginInstance

function plugin.contract(name: string, schema: number): PluginContractToken
  return native.plugin.contract(name, schema)
end

function plugin.capability<T>(name: string, schema: number, witness: (T) -> T): Capability<T>
  return adapter.capability(plugin.contract(name, schema), witness)
end

function plugin.define<C>(
  configWitness: (C) -> C,
  required: Declaration,
  provided: Declaration,
  init: (Context, C, Publisher) -> ()
): Definition<C>
  return adapter.define(configWitness, required, provided, init)
end

function plugin.runtime(): Runtime
  return adapter.runtime()
end

return plugin
