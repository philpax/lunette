-- Renders owner-scoped menu actions on a tracked wrist through the neutral UI service.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local config = require '@lunette-plugins/desktop/menu/config'
local geometry = require '@lunette-plugins/desktop/menu/geometry'
local rows = require '@lunette-plugins/desktop/menu/rows'

export type Hand = config.Hand
export type Config = config.Config
export type Settings = config.Settings

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/menu',
  schema = config.schema,
  requires = { ui = ui.capability, frame = frame.capability, menu = menu.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local uiService: ui.Service = context:require(ui.capability)
    local menuService: menu.Service = context:require(menu.capability)
    local frameService: frame.Service = context:require(frame.capability)
    local compact = geometry.layout(settings, false)
    local panel = uiService:newPanel(context, {
      name = 'desktop/menu',
      width = compact.width,
      height = compact.height,
      logicalWidth = compact.logicalWidth,
      logicalHeight = compact.logicalHeight,
      visible = false,
      grabbable = false,
      theme = {
        hapticStrength = settings.haptic.strength,
        hapticDuration = settings.haptic.duration,
        rowHeight = settings.expanded.rowHeight,
      },
    })
    local opened, tracked, dead = false, false, false
    local button: ui.Button? = nil
    local list: ui.List? = nil
    local snapshot: rows.Snapshot = {}
    context:effect(function(): () -> ()
      return function(): ()
        dead, tracked, opened = true, false, false
        snapshot = {}
      end
    end)
    local function live(): boolean
      return not dead and context:active() and not panel.dead
    end
    local rebuild: (boolean) -> ()
    rebuild = function(value: boolean): ()
      if not live() then
        return
      end
      opened = value
      if button and not button.dead then
        button:destroy()
      end
      if list and not list.dead then
        list:destroy()
      end
      button, list = nil, nil
      snapshot = {}
      local layout = geometry.layout(settings, opened)
      panel:setSize(layout.width, layout.height, layout.logicalWidth, layout.logicalHeight)
      button = panel:button(context, {
        id = if opened then 'close' else 'open',
        label = if opened then 'Close' else 'Menu',
        bounds = layout.button,
        onActivate = function(): ()
          if live() and tracked then
            rebuild(not opened)
          end
        end,
      })
      if opened and layout.actions then
        snapshot = menuService:list()
        list = panel:list(context, {
          id = 'actions',
          label = 'Actions',
          bounds = layout.actions,
          items = rows.items(snapshot),
          onChange = function(id: string): ()
            local current = list
            if not live() or not tracked or not opened or not current or current.dead then
              return
            end
            local descriptor = rows.find(snapshot, id)
            current:setSelected(nil)
            if descriptor and descriptor.enabled then
              -- Failed results are already reported by the broker; unavailable registrations are inert.
              menuService:invoke(descriptor.id, descriptor.registration)
            end
          end,
        })
      end
    end
    rebuild(false)
    frameService:onUpdate(context, {
      phase = 'scene',
      order = 1,
      run = function(_dt: number): ()
        if not live() then
          return
        end
        local device: Device = if settings.hand == 'left' then 'hand/left' else 'hand/right'
        local nextTracked = lovr.headset.isTracked(device)
        if not nextTracked then
          if tracked then
            panel:setVisible(false)
            if opened then
              rebuild(false)
            end
          end
          tracked = false
          return
        end
        panel:setPose(geometry.pose(settings))
        if not tracked then
          panel:setVisible(true)
        end
        tracked = true
        local current = list
        if opened and current and not current.dead then
          local replacement = menuService:list()
          if not rows.same(snapshot, replacement) then
            snapshot = replacement
            current:setItems(rows.items(snapshot))
          end
        end
      end,
    })
    frameService:onDraw(context, {
      phase = 'scene',
      order = 1,
      run = function(pass: Pass): ()
        if live() and tracked then
          panel:draw(pass)
        end
      end,
    })
  end,
}).definition
