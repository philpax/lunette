-- Renders owner-scoped menu actions on a tracked wrist through the UI host and the standard kinds.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local ui = require '@lunette-plugins/ui/react'
local config = require '@self/config'
local rows = require '@self/private/rows'
local view = require '@self/private/view'

export type Config = config.Config
export type Settings = config.Settings

local function wristPose(device: Device, offset: vector): Mat4
  local x, y, z, angle, ax, ay, az = lovr.headset.getPose(device)
  local pose = lovr.math.newMat4(x, y, z, angle, ax, ay, az)
  return pose:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/menu',
  schema = config.schema,
  requires = { uiHost.capability, uiComponents.capability, frame.capability, menu.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local menuService: menu.Service = context:require(menu.capability)
    local frameService: frame.Service = context:require(frame.capability)
    local expanded = settings.expanded
    -- The panel takes its content's size, so it is the closed button or the open list, centred on the wrist pose.
    local panel = host:newPanel(context, {
      name = 'desktop/menu',
      size = 'content',
      width = math.max(settings.size, expanded.width),
      height = math.max(settings.size, expanded.height),
      grabbable = false,
    })
    panel:setVisible(false)
    local device: Device = if settings.hand == 'left' then 'hand/left' else 'hand/right'
    local tracked = false
    local opened = ui.store(false)
    local snapshot = ui.store({} :: rows.Snapshot)
    local function live(): boolean
      return context:active() and not panel.dead
    end
    local function setOpened(value: boolean): ()
      if not live() then
        return
      end
      if value then
        snapshot:set(menuService:list())
      end
      opened:set(value)
    end
    ui.mount(
      panel,
      view.Menu {
        opened = opened,
        snapshot = snapshot,
        size = settings.size,
        width = expanded.width,
        height = expanded.height,
        open = function(): ()
          if tracked then
            setOpened(true)
          end
        end,
        close = function(): ()
          if tracked then
            setOpened(false)
          end
        end,
        invoke = function(descriptor: menu.Descriptor): ()
          if live() and tracked and opened:get() then
            -- Failed results are already reported by the broker; unavailable registrations are inert.
            menuService:invoke(descriptor.id, descriptor.token)
          end
        end,
      },
      { components = components, owner = context }
    )
    menuService:onChanged(context, {
      run = function(): ()
        if live() and opened:get() then
          snapshot:set(menuService:list())
        end
      end,
    })
    frameService:onUpdate(context, {
      phase = 'scene',
      order = 1,
      run = function(_dt: number): ()
        if not live() then
          return
        end
        if not lovr.headset.isTracked(device) then
          if tracked then
            panel:setVisible(false)
            setOpened(false)
          end
          tracked = false
          return
        end
        panel:setPose(wristPose(device, settings.offset))
        if not tracked then
          panel:setVisible(true)
        end
        tracked = true
      end,
    })
  end,
}
