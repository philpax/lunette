-- The placement provider: windows placed as panels, by resolved properties.
--
-- `panelOptions(properties, window, base)` is an around hook that answers the
-- options a window's panel is made with, and `base` maps pose, width, height,
-- title, priority, chrome, and curve. A hook that forwards a property of its
-- own, such as a curve chosen by a window's title, calls `base` and adds to
-- what it answers. Hiding and tags are not panel options: placement applies
-- `hidden` and `tags` itself after the panel is made.
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

-- What a configuration gives: every option optional.
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
