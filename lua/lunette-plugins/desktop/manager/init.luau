-- Owns the manager panel; the shared UI provider handles surface input and focus.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local ui = require '@lunette-contracts/ui'
local theme = require '@lunette-contracts/theme'
local composition = require '@lunette-contracts/composition'
local menu = require '@lunette-contracts/menu'
local config = require '@lunette-plugins/desktop/manager/config'
local controller = require '@lunette-plugins/desktop/manager/controller'
local brokers = require '@lunette-plugins/desktop/manager/brokers'
local widgets = require '@lunette-plugins/desktop/manager/widgets'

export type Config = config.Config
export type Settings = config.Settings

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/manager',
  schema = config.schema,
  requires = {
    composition.capability,
    frame.capability,
    ui.capability,
    theme.capability,
    menu.capability,
  },
  init = function(context: plugin.Context, settings: Settings): ()
    local compositionService = context:require(composition.capability)
    local frameService = context:require(frame.capability)
    local uiService = context:require(ui.capability)
    local menuService = context:require(menu.capability)
    local themeService = context:require(theme.capability)
    local pixelHeight = settings.pixels * settings.height / settings.width
    local dead = false
    local visible = settings.visible
    local untilRefresh = settings.refreshInterval
    local panel: ui.Panel
    local shell: widgets.Shell
    local registration: menu.Registration? = nil
    local function setVisible(show: boolean): ()
      if dead or panel.dead then
        return
      end
      visible = show
      panel:setVisible(show)
      if show then
        shell.update()
        untilRefresh = settings.refreshInterval
      else
        shell.cancel()
      end
      local handle = registration
      if handle then
        handle:update { selected = show }
      end
    end
    local function close(): ()
      setVisible(false)
    end
    local state = controller.new(compositionService, brokers.watch(context), settings.pixels, pixelHeight)
    state.presentation = settings.view
    panel = uiService:newPanel(context, {
      name = 'desktop/manager',
      pose = lovr.math.newMat4():translate(settings.position),
      width = settings.width,
      height = settings.height,
      logicalWidth = settings.pixels,
      logicalHeight = pixelHeight,
      visible = settings.visible,
      grabbable = true,
      titlebar = { title = 'Plugins', onClose = close },
    })
    shell = widgets.new(panel, context, state, themeService)
    context:effect(function(): () -> ()
      return function(): ()
        dead = true
        panel:destroy()
        shell.destroy()
      end
    end)
    registration = menuService:register(context, {
      id = 'desktop/manager/open',
      label = 'Plugins',
      group = 'Session',
      order = 20,
      selected = visible,
      run = function(): ()
        setVisible(not visible)
      end,
    })
    frameService:onUpdate(context, {
      phase = 'scene',
      run = function(dt: number): ()
        if dead or panel.dead or not visible then
          return
        end
        untilRefresh -= dt
        if untilRefresh <= 0 then
          untilRefresh = settings.refreshInterval
          shell.update()
        end
      end,
    })
    frameService:onDraw(context, {
      phase = 'scene',
      run = function(pass: Pass): ()
        if not dead and not panel.dead then
          panel:draw(pass)
        end
      end,
    })
  end,
}
