-- See docs/dev/lua-api.md#rules-and-placement for the placement options and hook.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local build = require '@lunette-plugins/placement/service'

export type Service = placement.Service
export type Properties = placement.Properties
export type PanelOptionsBase = build.PanelOptionsBase
export type PanelOptions = build.PanelOptions
export type Settings = build.Settings

export type Config = {
  read panelOptions: PanelOptions?,
}

local function panelOptions(properties: Properties, window: lunette.Window, base: PanelOptionsBase): panels.Options
  return base(properties, window)
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'placement',
  capability = placement.capability,
  requires = {
    panels = panels.capability,
    rules = rules.capability,
    tags = tags.capability,
  },
  defaults = { panelOptions = panelOptions },
  build = build.build,
}
