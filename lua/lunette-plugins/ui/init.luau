-- Publishes replaceable owner-scoped VR panels without installing a frame drawing order.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local panel = require '@lunette-plugins/ui/panel'
local config = require '@lunette-plugins/ui/config'
local cleanup = require '@lunette-plugins/ui/cleanup'
local validation = require '@lunette-plugins/ui/validation'
local titlebar = require '@lunette-plugins/ui/titlebar'
local theme = require '@lunette-contracts/theme'
local appearanceTheme = require '@lunette-plugins/ui/theme'
local titlebarStyle = require '@lunette-plugins/ui/titlebar-style'
local frame = require '@lunette-contracts/frame'
local records = require '@lunette-plugins/ui/panel-state'
local panelGeometry = require '@lunette-plugins/ui/panel-geometry'
local input = require '@lunette-plugins/ui/input'
local vocabulary = require '@lunette-contracts/vocabulary'

export type Config = config.Config
export type Settings = config.Settings

local function build(context: plugin.Context, settings: Settings): ui.Service
  local services: panel.Services = {
    focus = context:require(focus.capability),
    surfaces = context:require(surfaces.capability),
    owners = {},
    theme = context:require(theme.capability),
  }
  local generation: ui.Generation = { kind = 'ui-generation' }
  table.freeze(generation)
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
  local provider: panel.Provider = {
    context = context,
    services = services,
    theme = appearanceTheme.project(settings.theme),
    draw = settings.draw,
    generation = generation,
    newTitlebar = function(owner: ui.Owner, name: string, target: vocabulary.Surface, options: ui.TitlebarOptions)
      return service:newTitlebar(owner, name, target, options)
    end,
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
    newTitlebar = function(
      _self: ui.Service,
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
    end,
    panels = function(_self: ui.Service): { read [number]: ui.Panel }
      return table.freeze(livePanels())
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
  services.theme:onChanged(context, function(_snapshot: theme.Snapshot): ()
    if not context:active() then
      return
    end
    local operations: { () -> () } = {}
    for _, current in liveTitlebars() do
      operations[#operations + 1] = function(): ()
        if not current.dead then
          current:sync()
        end
      end
    end
    for _, current in livePanels() do
      local state = states[current]
      operations[#operations + 1] = function(): ()
        state.refresh()
      end
    end
    cleanup.run('ui appearance refresh', operations)
  end)
  return service
end

return plugin.provider<<Config, Settings, ui.Service>> {
  name = 'ui',
  schema = config,
  capability = ui.capability,
  requires = {
    focus = focus.capability,
    surfaces = surfaces.capability,
    theme = theme.capability,
    frame = frame.capability,
  },
  build = build,
}
