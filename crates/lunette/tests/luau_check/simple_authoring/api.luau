local plugin = require '@lunette-plugin'

export type Capability<T> = plugin.Capability<T>
export type Owner = plugin.Owner
export type Effect = plugin.Effect
export type Declaration = plugin.Declaration
export type Context = plugin.Context
export type Publisher = plugin.Publisher
export type Definition<C> = plugin.Definition<C>
export type Instance<C> = plugin.Instance<C>
export type Runtime = plugin.Runtime

return plugin
