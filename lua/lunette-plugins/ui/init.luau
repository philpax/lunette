-- Publishes replaceable owner-scoped VR panels without installing a frame drawing order.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local surface = require '@lunette-contracts/surface'
local panel = require '@lunette-plugins/ui/panel'
local config = require '@lunette-plugins/ui/config'
local owners = require '@lunette-plugins/ui/control-owners'
local validation = require '@lunette-plugins/ui/validation'
local titlebar = require '@lunette-plugins/ui/titlebar'
local theme = require '@lunette-contracts/theme'
local appearanceTheme = require '@lunette-plugins/ui/theme'
local titlebarStyle = require '@lunette-plugins/ui/titlebar-style'

export type Config = config.Config
export type Settings = config.Settings

local function build(context: plugin.Context, settings: Settings): ui.Service
  local providerTheme = appearanceTheme.project(settings.theme)
  local providerTitlebarStyle = titlebarStyle.project(settings.titlebarStyle)
  local registry: owners.Registry = {}
  local services: panel.Services = {
    focus = context:require(focus.capability),
    surfaces = context:require(surfaces.capability),
    owners = registry,
    theme = context:require(theme.capability),
  }
  local titlebars: { ui.Titlebar } = {}
  local panels: { ui.Panel } = {}
  local names: { [string]: boolean } = {}
  local generation: ui.Generation = { kind = 'ui-generation' }
  table.freeze(generation)
  local service: ui.Service
  service = {
    newPanel = function(_self: ui.Service, owner: ui.Owner, options: ui.PanelOptions): ui.Panel
      context:checkOwner(owner)
      options = validation.panel(options)
      local name = options.name
      assert(not names[name], 'ui: duplicate panel name ' .. tostring(name))
      local created: ui.Panel
      names[name] = true
      local ok, result = pcall(function(): ui.Panel
        return panel.new(
          context,
          owner,
          options,
          services,
          providerTheme,
          settings.draw,
          generation,
          function(name, target, given)
            return service:newTitlebar(owner, name, target, given)
          end,
          function(): ()
            names[name] = nil
            local index = table.find(panels, created)
            if index then
              table.remove(panels, index)
            end
          end
        )
      end)
      if not ok then
        names[name] = nil
        error(result, 0)
      end
      created = result
      panels[#panels + 1] = created
      return created
    end,
    newTitlebar = function(
      _self: ui.Service,
      owner: ui.Owner,
      name: string,
      target: surface.Surface,
      options: ui.TitlebarOptions,
      visible: (() -> boolean)?
    ): ui.Titlebar
      local created: ui.Titlebar? = nil
      local result = titlebar.new(
        context,
        owner,
        name,
        target,
        options,
        visible,
        service,
        services.surfaces,
        providerTitlebarStyle,
        services.theme,
        function(): ()
          if created then
            local index = table.find(titlebars, created)
            if index then
              table.remove(titlebars, index)
            end
            created = nil
          end
        end
      )
      created = result
      if not result.dead then
        titlebars[#titlebars + 1] = result
      end
      return result
    end,
    panels = function(_self: ui.Service): { read [number]: ui.Panel }
      local result: { ui.Panel } = {}
      for _, current in ipairs(panels) do
        if not current.dead then
          result[#result + 1] = current
        end
      end
      return table.freeze(result)
    end,
  }
  services.theme:onChanged(context, function(_snapshot: theme.Snapshot): ()
    if not context:active() then
      return
    end
    local failures: { string } = {}
    local function attempt(run: () -> ()): ()
      local ok, failure = pcall(run)
      if not ok then
        failures[#failures + 1] = tostring(failure)
      end
    end
    for _, current in table.clone(titlebars) do
      if not current.dead then
        attempt(function(): ()
          current:sync()
        end)
      end
    end
    for _, current in table.clone(panels) do
      if not current.dead then
        attempt(function(): ()
          current:describe()
        end)
      end
    end
    if #failures > 0 then
      error('ui appearance refresh: ' .. table.concat(failures, '; '), 0)
    end
  end)
  return service
end

return plugin.provider<<Config, Settings, ui.Service>> {
  name = 'ui',
  schema = config,
  capability = ui.capability,
  requires = { focus = focus.capability, surfaces = surfaces.capability, theme = theme.capability },
  build = build,
}
