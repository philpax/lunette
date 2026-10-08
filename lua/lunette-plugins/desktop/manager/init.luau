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
local styles = require '@lunette-plugins/desktop/manager/theme'
local widgets = require '@lunette-plugins/desktop/manager/widgets'

export type Config = config.Config
export type Settings = config.Settings

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/manager',
  schema = config.schema,
  requires = {
    composition = composition.capability,
    frame = frame.capability,
    ui = ui.capability,
    theme = theme.capability,
    menu = menu.capability,
  },
  init = function(context: plugin.Context, settings: Settings): ()
    local compositionService = context:require(composition.capability)
    local frameService = context:require(frame.capability)
    local uiService = context:require(ui.capability)
    local menuService = context:require(menu.capability)
    local themeService = context:require(theme.capability)
    local style = styles.new(themeService, context)
    local pixelHeight = settings.pixels * settings.height / settings.width
    local dead = false
    local visible = settings.visible
    local untilRefresh = settings.refreshInterval
    local panel: ui.Panel
    local shell: widgets.Shell?
    local registration: plugin.Effect? = nil
    local function setVisible(show: boolean): ()
      if dead or not context:active() or panel.dead then
        return
      end
      visible = show
      panel:setVisible(show)
      local current = shell
      if current then
        if show then
          current.update()
        else
          current.cancel()
        end
      end
      if show then
        untilRefresh = settings.refreshInterval
      end
      local handle = registration
      if handle then
        menuService:update(context, handle, { selected = show })
      end
    end
    local function close(): ()
      setVisible(false)
    end
    local state = controller.new(compositionService, brokers.watch(context), settings.pixels, pixelHeight, nil, close)
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
    state.presentation = settings.view
    local initial = style.current()
    controller.prepareStyle(state, initial.metrics.rowHeight, initial.metrics.spacing, nil)()
    shell = widgets.new(panel, context, state, style)
    themeService:onChanged(context, function(_snapshot: theme.Snapshot): ()
      local current = shell
      if current and not dead and context:active() and not panel.dead then
        current.refreshTheme()
      end
    end)
    context:effect(function(): () -> ()
      return function(): ()
        dead = true
        local current = shell
        shell = nil
        panel:destroy()
        if current then
          current.destroy()
        end
        style.destroy()
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
        local current = shell
        if dead or not context:active() or not current or panel.dead or not visible then
          return
        end
        untilRefresh -= dt
        if untilRefresh <= 0 then
          untilRefresh = settings.refreshInterval
          current.update()
        end
      end,
    })
    frameService:onDraw(context, {
      phase = 'scene',
      run = function(pass: Pass): ()
        local current = shell
        if not dead and context:active() and not panel.dead and current then
          current.refreshTheme()
          if dead or not context:active() or panel.dead then
            return
          end
          style.withFont(function(_font: Font, _tokens: theme.Theme): ()
            panel:draw(pass)
          end)
        end
      end,
    })
  end,
}).definition
