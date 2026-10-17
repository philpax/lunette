-- Renders owner-scoped menu actions on a tracked wrist through the UI host and the standard kinds. Grabbing the open
-- menu tears it off the wrist: it stays where it is released, as a world panel, until it is closed, when it returns to
-- the wrist.
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

-- Whether a grab moved the panel from the pose the menu last gave it.
local function moved(panel: uiHost.Panel, placed: { number }): boolean
  for index, value in { panel:pose():unpack(true) } do
    if math.abs(value - placed[index]) > 1e-6 then
      return true
    end
  end
  return false
end

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
    -- Set while the open menu is torn off the wrist.
    local detached = false
    local shown = false
    -- The pose the menu last placed the panel at on the wrist, which a grab changes.
    local placed: { number }? = nil
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
      else
        detached = false
      end
      -- Only the open menu tears off; the closed button stays on the wrist.
      panel:setGrabbable(value)
      opened:set(value)
    end
    local function reachable(): boolean
      return tracked or detached
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
          if reachable() then
            setOpened(false)
          end
        end,
        invoke = function(descriptor: menu.Descriptor): ()
          if live() and reachable() and opened:get() then
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
        if not detached and placed and opened:get() and moved(panel, placed) then
          detached = true
        end
        local isTracked = lovr.headset.isTracked(device)
        if detached then
          tracked = isTracked
          return
        end
        if not isTracked then
          -- The menu also hides here when it was closed while torn off from an untracked hand.
          if shown then
            shown = false
            panel:setVisible(false)
            setOpened(false)
          end
          tracked = false
          placed = nil
          return
        end
        local pose = wristPose(device, settings.offset)
        panel:setPose(pose)
        placed = { pose:unpack(true) }
        if not shown then
          shown = true
          panel:setVisible(true)
        end
        tracked = true
      end,
    })
  end,
}
