-- Owns the manager panel; the shared UI provider handles surface input and focus.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local ui = require '@lunette-contracts/ui'
local composition = require '@lunette-contracts/composition'
local menu = require '@lunette-contracts/menu'
local config = require '@lunette-plugins/desktop/manager/config'
local controller = require '@lunette-plugins/desktop/manager/controller'
local brokers = require '@lunette-plugins/desktop/manager/brokers'
local draw = require '@lunette-plugins/desktop/manager/draw'
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
    menu = menu.capability,
  },
  init = function(context: plugin.Context, settings: Settings): ()
    local compositionService = context:require(composition.capability)
    local frameService = context:require(frame.capability)
    local uiService = context:require(ui.capability)
    local menuService = context:require(menu.capability)
    local pixelHeight = settings.pixels * settings.height / settings.width
    local dead = false
    local visible = settings.visible
    local untilRefresh = settings.refreshInterval
    local panel: ui.Panel
    local shell: widgets.Shell?
    local state = controller.new(
      compositionService,
      brokers.watch(context),
      settings.pixels,
      pixelHeight,
      function(records, sidebar): { string }
        return draw.wrapDetails(lovr.graphics.getDefaultFont(), records, sidebar)
      end,
      function(): ()
        if dead then
          return
        end
        visible = false
        panel:setVisible(false)
        local current = shell
        if current then
          current.cancel()
        end
      end
    )
    panel = uiService:newPanel(context, {
      name = 'desktop/manager',
      pose = lovr.math.newMat4():translate(settings.position),
      width = settings.width,
      height = settings.height,
      logicalWidth = settings.pixels,
      logicalHeight = pixelHeight,
      visible = settings.visible,
      grabbable = true,
    })
    state.presentation = settings.view
    shell = widgets.new(panel, context, state)
    context:effect(function(): () -> ()
      return function(): ()
        dead = true
        local current = shell
        shell = nil
        panel:destroy()
        if current then
          current.destroy()
        end
      end
    end)
    menuService:register(context, {
      id = 'desktop/manager/open',
      label = 'Plugins',
      group = 'Session',
      order = 20,
      run = function(): ()
        if not dead and context:active() and not panel.dead then
          local current = shell
          if current then
            current.update()
          end
          visible = true
          untilRefresh = settings.refreshInterval
          panel:setVisible(true)
        end
      end,
    })
    frameService:onUpdate(context, {
      phase = 'scene',
      run = function(dt: number): ()
        local current = shell
        if dead or not current or panel.dead or not visible then
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
      phase = 'overlay',
      order = 1000,
      run = function(pass: Pass): ()
        if not dead and not panel.dead then
          panel:draw(pass)
        end
      end,
    })
  end,
}).definition
