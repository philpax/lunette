local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'

export type PanelOptionsBase = (placement.Properties, lunette.Window) -> panels.Options
export type PanelOptions = (placement.Properties, lunette.Window, PanelOptionsBase) -> panels.Options

local function panelOptions(
  properties: placement.Properties,
  window: lunette.Window,
  base: PanelOptionsBase
): panels.Options
  return base(properties, window)
end

type ConfigurationShape<F> = { panelOptions: schema.Schema<F?, F> }
local function configuration<F>(hook: F): schema.Schema<
  schema.ObjectInput<ConfigurationShape<F>>,
  schema.ObjectOutput<ConfigurationShape<F>>
>
  local callback = schema.callback(hook)
  return schema.object {
    panelOptions = schema.default(callback)(hook),
  }
end
local SCHEMA = configuration<<PanelOptions>>(panelOptions)

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
