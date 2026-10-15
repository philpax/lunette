-- Publishes replaceable owner-scoped VR panels without installing a frame drawing order.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local panel = require '@self/private/panels/panel'
local config = require '@self/config'
local validation = require '@self/private/validation'
local titlebar = require '@self/private/titlebar/titlebar'
local theme = require '@lunette-contracts/theme'
local appearanceTheme = require '@self/private/rendering/theme'
local titlebarStyle = require '@lunette-plugins/ui/titlebar-configuration'
local frame = require '@lunette-contracts/frame'
local records = require '@self/private/panels/panel-state'
local panelGeometry = require '@self/private/panels/panel-geometry'
local input = require '@self/private/controls/input'
local vocabulary = require '@lunette-contracts/vocabulary'
local inspection = require '@lunette-contracts/inspection'
local panelInspection = require '@self/private/panels/panel-inspection'

export type Config = config.Config
export type Settings = config.Settings

local function build(context: plugin.Context, settings: Settings): ui.Service
  local services: panel.Services = {
    focus = context:require(focus.capability),
    surfaces = context:require(surfaces.capability),
    owners = {},
    theme = context:require(theme.capability),
  }
  -- Destroyed panels and titlebars stay listed until the next pass over each list prunes them.
  local panels: { ui.Panel } = {}
  local states: { [ui.Panel]: records.Panel } = {}
  local titlebars: { ui.Titlebar } = {}
  local function livePanels(): { ui.Panel }
    local live: { ui.Panel } = {}
    for _, current in panels do
      if current.dead then
        states[current] = nil
      else
        live[#live + 1] = current
      end
    end
    panels = live
    return table.clone(live)
  end
  local function liveTitlebars(): { ui.Titlebar }
    local live: { ui.Titlebar } = {}
    for _, current in titlebars do
      if not current.dead then
        live[#live + 1] = current
      end
    end
    titlebars = live
    return table.clone(live)
  end
  local service: ui.Service
  local titlebarProvider: titlebar.Provider
  local function newTitlebar(
    owner: ui.Owner,
    name: string,
    target: vocabulary.Surface,
    options: ui.TitlebarOptions,
    visible: (() -> boolean)?
  ): ui.Titlebar
    local result = titlebar.new(titlebarProvider, owner, name, target, options, visible)
    if not result.dead then
      titlebars[#titlebars + 1] = result
    end
    return result
  end
  local provider: panel.Provider = {
    context = context,
    services = services,
    theme = appearanceTheme.project(settings.theme),
    newTitlebar = newTitlebar,
  }
  service = {
    newPanel = function(_self: ui.Service, owner: ui.Owner, options: ui.PanelOptions): ui.Panel
      context:checkOwner(owner)
      options = validation.panel(options)
      for _, current in livePanels() do
        assert(states[current].name ~= options.name, 'ui: duplicate panel name ' .. options.name)
      end
      local handle, state = panel.new(provider, owner, options)
      panels[#panels + 1] = handle
      states[handle] = state
      return handle
    end,
    newTitlebar = function(_self: ui.Service, owner: ui.Owner, spec: ui.TitlebarSpec): ui.Titlebar
      assert(type(spec) == 'table' and getmetatable(spec) == nil, 'ui titlebar: the spec is a plain table')
      local options = table.clone(spec) :: { [string]: unknown }
      options.name, options.target, options.visible = nil, nil, nil
      local visible = spec.visible
      assert(visible == nil or type(visible) == 'function', 'ui titlebar: visible is a function')
      return newTitlebar(owner, spec.name, spec.target, (options :: any) :: ui.TitlebarOptions, visible)
    end,
    inspect = function(_self: ui.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      local function live(owner: ui.Owner): boolean
        return context:active() and context:owns(owner)
      end
      for _, current in livePanels() do
        panelInspection.append(result, states[current], live)
      end
      return inspection.snapshot(result, nil, { 'draw hooks and control callbacks are not run' })
    end,
  }
  titlebarProvider = {
    context = context,
    service = service,
    surfaces = services.surfaces,
    style = titlebarStyle.project(settings.titlebarStyle),
    themes = services.theme,
    contour = function(handle: ui.Panel, contour: records.Contour): ()
      local state = assert(states[handle], 'ui titlebar: missing action panel')
      state.contour = contour
      state.revision += 1
      panelGeometry.prepare(state)
      input.cancel(state, nil, 'control-removed')
    end,
    size = function(handle: ui.Panel): (number, number)
      local state = assert(states[handle], 'ui titlebar: missing action panel')
      return state.width, state.height
    end,
  }
  context:require(frame.capability):onUpdate(context, {
    phase = 'scene',
    order = 1000,
    run = function(_dt: number): ()
      for _, current in liveTitlebars() do
        if not current.dead then
          current:sync()
        end
      end
    end,
  })
  return service
end

return plugin.provider<<Config, Settings, ui.Service>> {
  name = 'ui',
  schema = config.schema,
  capability = ui.capability,
  requires = {
    focus.capability,
    surfaces.capability,
    theme.capability,
    frame.capability,
  },
  build = build,
}
